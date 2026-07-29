//! Lighthouse-side view of NAT source-port allocation.
//!
//! A client can only observe "I cannot reach the mesh". Attributing an outage to
//! port contention requires the lighthouse's vantage point: which `certName`
//! currently holds the external port every node defaults to. That is exactly how
//! the 2026-07-28 root cause was found, by aggregating `journalctl -u nebula`
//! per node and looking at the source ports the NAT handed out.
//!
//! This module parses those log lines and folds them into bounded buckets. It is
//! deliberately read-only: nothing here talks to nebula or changes its config.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use rusqlite::Connection;

/// Matches the probe bucket width so both views line up on the same time axis.
pub const BUCKET_WIDTH_S: f64 = 300.0;

/// One node's observed source address in a single log line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LighthouseSample {
    pub cert_name: String,
    pub wan_ip: String,
    pub source_port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LighthouseRow {
    pub bucket_at: i64,
    pub cert_name: String,
    pub wan_ip: String,
    pub source_port: u16,
    pub packets: i64,
}

/// Extracts `certName` and the observed source address from one nebula log line.
///
/// Both `from=` and `udpAddr=` are accepted: the field name differs between
/// nebula's handshake and lighthouse messages, and which one carries the address
/// has not been confirmed against a live lighthouse yet. Values may or may not be
/// quoted, so quotes are stripped rather than required.
pub fn parse_line(line: &str) -> Option<LighthouseSample> {
    let cert_name = field(line, "certName=")?;
    let address = field(line, "from=").or_else(|| field(line, "udpAddr="))?;
    let (wan_ip, port) = address.rsplit_once(':')?;
    let source_port = port.parse().ok()?;
    if wan_ip.is_empty() || cert_name.is_empty() {
        return None;
    }
    Some(LighthouseSample {
        cert_name,
        wan_ip: wan_ip.to_string(),
        source_port,
    })
}

/// Reads the value of `key` up to the next whitespace, trimming quotes and any
/// surrounding brackets that nebula uses for address lists.
fn field(line: &str, key: &str) -> Option<String> {
    let start = line.find(key)? + key.len();
    let rest = &line[start..];
    let value = if let Some(stripped) = rest.strip_prefix('"') {
        stripped.split('"').next()?
    } else {
        rest.split_whitespace().next()?
    };
    let value = value.trim_matches(|c| c == '[' || c == ']' || c == '"');
    (!value.is_empty()).then(|| value.to_string())
}

pub fn bucket_start(time: f64) -> i64 {
    ((time / BUCKET_WIDTH_S).floor() * BUCKET_WIDTH_S) as i64
}

pub fn create_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS lighthouse_observation (
            bucket_at INTEGER NOT NULL,
            cert_name TEXT NOT NULL,
            wan_ip TEXT NOT NULL,
            source_port INTEGER NOT NULL,
            packets INTEGER NOT NULL,
            PRIMARY KEY (bucket_at, cert_name, wan_ip, source_port)
        );
        CREATE INDEX IF NOT EXISTS idx_lighthouse_bucket
            ON lighthouse_observation(bucket_at);",
    )
}

/// Folds a batch of samples into their bucket. Row count is bounded by bucket
/// width times nodes times distinct ports, so like every other table here it
/// needs no pruning.
pub fn record(
    connection: &Connection,
    samples: &[LighthouseSample],
    at: f64,
) -> rusqlite::Result<()> {
    let bucket = bucket_start(at);
    let mut counts: HashMap<(&str, &str, u16), i64> = HashMap::new();
    for sample in samples {
        *counts
            .entry((&sample.cert_name, &sample.wan_ip, sample.source_port))
            .or_insert(0) += 1;
    }
    for ((cert_name, wan_ip, port), packets) in counts {
        connection.execute(
            "INSERT INTO lighthouse_observation
               (bucket_at, cert_name, wan_ip, source_port, packets)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(bucket_at, cert_name, wan_ip, source_port) DO UPDATE SET
               packets = packets + excluded.packets",
            rusqlite::params![bucket, cert_name, wan_ip, port, packets],
        )?;
    }
    Ok(())
}

pub fn rows(connection: &Connection, since: i64) -> rusqlite::Result<Vec<LighthouseRow>> {
    let mut statement = connection.prepare(
        "SELECT bucket_at, cert_name, wan_ip, source_port, packets
         FROM lighthouse_observation WHERE bucket_at >= ?1
         ORDER BY bucket_at, cert_name",
    )?;
    let rows = statement.query_map([since], |row| {
        Ok(LighthouseRow {
            bucket_at: row.get(0)?,
            cert_name: row.get(1)?,
            wan_ip: row.get(2)?,
            source_port: row.get(3)?,
            packets: row.get(4)?,
        })
    })?;
    rows.collect()
}

/// Which node currently holds `port` behind each WAN address, and which nodes
/// were pushed onto a rewritten port. This is the query the root-cause analysis
/// actually needed: under a port-preserving NAT only one node can hold the
/// default port at a time, and the rest lose their mapping shortly after.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentionView {
    pub wan_ip: String,
    pub holder: Option<String>,
    pub rewritten: Vec<String>,
}

pub fn contention(rows: &[LighthouseRow], default_port: u16) -> Vec<ContentionView> {
    let mut by_wan: HashMap<&str, (Option<(&str, i64)>, Vec<&str>)> = HashMap::new();
    for row in rows {
        let entry = by_wan.entry(&row.wan_ip).or_insert((None, Vec::new()));
        if row.source_port == default_port {
            // Keep the node with the most packets on the default port; ties go to
            // whichever was seen first, which is stable for a sorted input.
            if entry.0.is_none_or(|(_, packets)| row.packets > packets) {
                entry.0 = Some((&row.cert_name, row.packets));
            }
        } else if !entry.1.contains(&row.cert_name.as_str()) {
            entry.1.push(&row.cert_name);
        }
    }
    let mut views: Vec<ContentionView> = by_wan
        .into_iter()
        .map(|(wan_ip, (holder, mut rewritten))| {
            rewritten.sort_unstable();
            ContentionView {
                wan_ip: wan_ip.to_string(),
                holder: holder.map(|(name, _)| name.to_string()),
                rewritten: rewritten.into_iter().map(String::from).collect(),
            }
        })
        .collect();
    views.sort_by(|a, b| a.wan_ip.cmp(&b.wan_ip));
    views
}

/// Where the nebula log is read from. A fixed `journalctl -u <unit>` invocation
/// or a plain file — never an arbitrary command from the config file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogSource {
    Journal { unit: String },
    File { path: PathBuf },
}

#[derive(Debug, Clone)]
pub struct LighthouseConfig {
    pub source: LogSource,
    pub default_port: u16,
    pub listen: String,
    pub interval: Duration,
}

/// Reads whatever arrived since the last call.
///
/// The file reader tracks a byte offset so nothing is counted twice; the journal
/// reader asks for one interval's worth, which double-counts or misses a little
/// at the boundaries. That is acceptable: the question this answers is which
/// node holds the port, and that is decided by relative volume, not exact counts.
pub struct LogReader {
    source: LogSource,
    offset: u64,
    inode: Option<u64>,
}

impl LogReader {
    pub fn new(source: LogSource) -> Self {
        Self {
            source,
            offset: 0,
            inode: None,
        }
    }

    pub fn read_new(&mut self, window: Duration) -> std::io::Result<String> {
        match &self.source {
            LogSource::Journal { unit } => {
                let since = format!("{} seconds ago", window.as_secs().max(1));
                let output = Command::new("journalctl")
                    .args(["-u", unit, "--since", &since, "--no-pager"])
                    .output()?;
                if !output.status.success() {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Other,
                        format!("journalctl -u {unit} failed"),
                    ));
                }
                Ok(String::from_utf8_lossy(&output.stdout).into_owned())
            }
            LogSource::File { path } => {
                let mut file = File::open(path)?;
                let metadata = file.metadata()?;
                let length = metadata.len();
                let inode = metadata.ino();
                // Length alone cannot detect rotation: a replacement file may
                // already be longer than the previous offset, which would
                // silently skip everything written before it. Compare the inode
                // as well, and treat a shorter file as an in-place truncation.
                if self.inode.is_some_and(|previous| previous != inode) || length < self.offset {
                    self.offset = 0;
                }
                self.inode = Some(inode);
                file.seek(SeekFrom::Start(self.offset))?;
                let mut text = String::new();
                file.read_to_string(&mut text)?;
                self.offset = length;
                Ok(text)
            }
        }
    }
}

pub fn parse_batch(text: &str) -> Vec<LighthouseSample> {
    text.lines().filter_map(parse_line).collect()
}

pub fn snapshot_json(rows: &[LighthouseRow], default_port: u16, now: i64) -> String {
    let views = contention(rows, default_port);
    let wan = views
        .iter()
        .map(|view| {
            let rewritten = view
                .rewritten
                .iter()
                .map(|name| format!("{}", serde_json::Value::String(name.clone())))
                .collect::<Vec<_>>()
                .join(",");
            let holder = match &view.holder {
                Some(name) => serde_json::Value::String(name.clone()).to_string(),
                None => "null".to_string(),
            };
            format!(
                r#"{{"wan_ip":{},"holder":{holder},"rewritten":[{rewritten}]}}"#,
                serde_json::Value::String(view.wan_ip.clone())
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"schema_version":1,"generated_at":{now},"default_port":{default_port},"wan":[{wan}]}}"#
    )
}

/// Runs the collector and serves the aggregate read-only.
///
/// Deliberately outside the usage cluster: this process never pairs, never holds
/// a cluster secret and never reports usage, so a lighthouse VPS cannot show up
/// as a zero-token node in anyone's aggregate view. Consumers poll it instead.
pub fn run_headless(database: &Path, config: LighthouseConfig) -> anyhow::Result<()> {
    let connection = crate::source::local::db::open_db(database)?;
    create_schema(&connection)?;
    let listener = TcpListener::bind(&config.listen)?;
    listener.set_nonblocking(true)?;
    let mut reader = LogReader::new(config.source.clone());
    let mut last_collect = Instant::now()
        .checked_sub(config.interval)
        .unwrap_or_else(Instant::now);

    loop {
        if last_collect.elapsed() >= config.interval {
            match reader.read_new(config.interval) {
                Ok(text) => {
                    let samples = parse_batch(&text);
                    if !samples.is_empty() {
                        let _ = record(&connection, &samples, crate::util::epoch_now() as f64);
                    }
                }
                // A transient read failure must not kill the collector; the next
                // tick retries and the endpoint keeps serving what is stored.
                Err(error) => eprintln!("lighthouse: log read failed: {error}"),
            }
            last_collect = Instant::now();
        }
        match listener.accept() {
            Ok((stream, _)) => {
                let stored = rows(&connection, 0).unwrap_or_default();
                let body = snapshot_json(&stored, config.default_port, crate::util::epoch_now());
                let _ = respond(stream, &body);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn respond(mut stream: TcpStream, body: &str) -> std::io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    // The request line is irrelevant: this endpoint serves exactly one document.
    let mut discard = [0u8; 1024];
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.read(&mut discard);
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(cert: &str, ip: &str, port: u16) -> LighthouseSample {
        LighthouseSample {
            cert_name: cert.into(),
            wan_ip: ip.into(),
            source_port: port,
        }
    }

    #[test]
    fn parses_quoted_and_unquoted_address_fields() {
        let quoted = r#"time="2026-07-28T15:02:11Z" level=info msg="Handshake message received" certName=DS925 from="123.158.49.251:4242" vpnAddrs="[192.168.100.125]""#;
        assert_eq!(
            parse_line(quoted),
            Some(sample("DS925", "123.158.49.251", 4242))
        );

        let unquoted = "level=info certName=MBA-M2 udpAddr=223.95.78.14:61571";
        assert_eq!(
            parse_line(unquoted),
            Some(sample("MBA-M2", "223.95.78.14", 61571))
        );
    }

    #[test]
    fn rejects_lines_without_both_fields() {
        assert!(parse_line("level=info msg=\"Tunnel status\" certName=Bandwagon2").is_none());
        assert!(parse_line("from=\"1.2.3.4:4242\"").is_none());
        assert!(parse_line("certName=X from=\"not-an-address\"").is_none());
        assert!(parse_line("").is_none());
    }

    #[test]
    fn folds_repeated_samples_into_one_bucket_row() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        let batch = vec![
            sample("DS925", "123.158.49.251", 4242),
            sample("DS925", "123.158.49.251", 4242),
            sample("MBA-M2", "123.158.49.251", 42207),
        ];
        record(&connection, &batch, 1_700_000_000.0).unwrap();
        record(&connection, &batch[..1], 1_700_000_050.0).unwrap();

        let stored = rows(&connection, 0).unwrap();
        assert_eq!(stored.len(), 2);
        let ds925 = stored.iter().find(|row| row.cert_name == "DS925").unwrap();
        assert_eq!(ds925.packets, 3);
        assert_eq!(ds925.bucket_at, 1_699_999_800);
    }

    /// Reproduces the morning row of the post-mortem table: DS925 holds 4242
    /// while the other two are pushed onto rewritten ports.
    #[test]
    fn contention_names_the_holder_and_the_displaced() {
        let rows = vec![
            LighthouseRow {
                bucket_at: 0,
                cert_name: "DS925".into(),
                wan_ip: "123.158.49.251".into(),
                source_port: 4242,
                packets: 40,
            },
            LighthouseRow {
                bucket_at: 0,
                cert_name: "MBA-M2".into(),
                wan_ip: "123.158.49.251".into(),
                source_port: 42207,
                packets: 5,
            },
            LighthouseRow {
                bucket_at: 0,
                cert_name: "Mini-M4".into(),
                wan_ip: "123.158.49.251".into(),
                source_port: 61571,
                packets: 3,
            },
        ];
        let views = contention(&rows, 4242);
        assert_eq!(views.len(), 1);
        assert_eq!(views[0].holder.as_deref(), Some("DS925"));
        assert_eq!(views[0].rewritten, vec!["MBA-M2", "Mini-M4"]);
    }

    /// After a re-dial the mesh is split across two WAN addresses; each is
    /// contended independently.
    #[test]
    fn contention_is_reported_per_wan_address() {
        let rows = vec![
            LighthouseRow {
                bucket_at: 0,
                cert_name: "WSL".into(),
                wan_ip: "124.90.54.149".into(),
                source_port: 4242,
                packets: 10,
            },
            LighthouseRow {
                bucket_at: 0,
                cert_name: "DS925".into(),
                wan_ip: "124.90.54.149".into(),
                source_port: 1160,
                packets: 2,
            },
            LighthouseRow {
                bucket_at: 0,
                cert_name: "iMac".into(),
                wan_ip: "8.8.8.8".into(),
                source_port: 4242,
                packets: 7,
            },
        ];
        let views = contention(&rows, 4242);
        assert_eq!(views.len(), 2);
        assert_eq!(views[0].wan_ip, "124.90.54.149");
        assert_eq!(views[0].holder.as_deref(), Some("WSL"));
        assert_eq!(views[0].rewritten, vec!["DS925"]);
        assert_eq!(views[1].holder.as_deref(), Some("iMac"));
        assert!(views[1].rewritten.is_empty());
    }

    #[test]
    fn snapshot_json_is_valid_and_names_the_holder() {
        let rows = vec![
            LighthouseRow {
                bucket_at: 0,
                cert_name: "DS925".into(),
                wan_ip: "123.158.49.251".into(),
                source_port: 4242,
                packets: 40,
            },
            LighthouseRow {
                bucket_at: 0,
                cert_name: "MBA-M2".into(),
                wan_ip: "123.158.49.251".into(),
                source_port: 42207,
                packets: 5,
            },
        ];
        let body = snapshot_json(&rows, 4242, 1_700_000_000);
        let parsed: serde_json::Value = serde_json::from_str(&body).expect("valid JSON");
        assert_eq!(parsed["default_port"], 4242);
        assert_eq!(parsed["wan"][0]["wan_ip"], "123.158.49.251");
        assert_eq!(parsed["wan"][0]["holder"], "DS925");
        assert_eq!(parsed["wan"][0]["rewritten"][0], "MBA-M2");
    }

    #[test]
    fn snapshot_json_survives_an_empty_database_and_absent_holder() {
        let empty: serde_json::Value =
            serde_json::from_str(&snapshot_json(&[], 4242, 1)).expect("valid JSON");
        assert_eq!(empty["wan"].as_array().map(Vec::len), Some(0));

        let rows = vec![LighthouseRow {
            bucket_at: 0,
            cert_name: "Mini-M4".into(),
            wan_ip: "223.95.78.14".into(),
            source_port: 53818,
            packets: 4,
        }];
        let parsed: serde_json::Value =
            serde_json::from_str(&snapshot_json(&rows, 4242, 1)).expect("valid JSON");
        assert!(parsed["wan"][0]["holder"].is_null());
    }

    /// A rotated or truncated file must reset the offset instead of seeking past EOF.
    #[test]
    fn file_reader_only_returns_new_bytes_and_handles_rotation() {
        let dir = std::env::temp_dir().join(format!("elink-lh-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nebula.log");
        std::fs::write(&path, "certName=A from=\"1.1.1.1:4242\"\n").unwrap();
        let mut reader = LogReader::new(LogSource::File { path: path.clone() });

        let first = reader.read_new(Duration::from_secs(60)).unwrap();
        assert_eq!(parse_batch(&first).len(), 1);
        let second = reader.read_new(Duration::from_secs(60)).unwrap();
        assert!(second.is_empty(), "already-read bytes must not repeat");

        // Rotation replaces the file, so the new one has a different inode even
        // though it is the same length as the bytes already consumed.
        std::fs::remove_file(&path).unwrap();
        std::fs::write(&path, "certName=B from=\"2.2.2.2:4242\"\n").unwrap();
        let after_rotation = reader.read_new(Duration::from_secs(60)).unwrap();
        assert_eq!(parse_batch(&after_rotation).len(), 1);

        // Truncation in place keeps the inode but shortens the file.
        std::fs::write(&path, "certName=C from=\"3.3.3.3:42\"\n").unwrap();
        let after_truncation = reader.read_new(Duration::from_secs(60)).unwrap();
        assert_eq!(parse_batch(&after_truncation).len(), 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Nobody on the default port is a valid state: every node was rewritten.
    #[test]
    fn contention_tolerates_an_absent_holder() {
        let rows = vec![LighthouseRow {
            bucket_at: 0,
            cert_name: "Mini-M4".into(),
            wan_ip: "223.95.78.14".into(),
            source_port: 53818,
            packets: 4,
        }];
        let views = contention(&rows, 4242);
        assert_eq!(views[0].holder, None);
        assert_eq!(views[0].rewritten, vec!["Mini-M4"]);
    }
}
