//! Lighthouse-side view of NAT source-port allocation.
//!
//! A client can only observe "I cannot reach the mesh". Attributing an outage to
//! port contention requires the lighthouse's vantage point: which `certName`
//! currently holds the external port every node defaults to. That is exactly how
//! the 2026-07-28 root cause was found, by aggregating `journalctl -u nebula`
//! per node and looking at the source ports the NAT handed out.
//!
//! This module parses those log lines and folds them into bounded buckets.
//!
//! It also keeps the mesh roster and probes it. Liveness cannot be read out of
//! the log: nebula logs state *changes*, so a tunnel that has been up for a day
//! is silent while a node stuck in a handshake loop is the noisiest thing in
//! the file — the log's most active node is usually its most broken one. Only
//! an active probe answers "is this node reachable right now", and the
//! lighthouse's answer is what lets a client tell "that node is down" apart
//! from "only my tunnel to it is down".
//!
//! Nothing here changes nebula's configuration or talks to its control plane;
//! the only packets it originates are ICMP echoes on the overlay.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use chrono::DateTime;
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
/// `from=` only, confirmed against a live lighthouse: over three days it carried
/// 21825 lines while `udpAddr=` appeared on 29, every one of them a `Host roamed
/// to new udp ip/port.` line where it holds the address the node just *left* —
/// `newAddr=` holds the new one. Accepting it recorded each roaming node under
/// the port it had already given up.
///
/// `newAddr=` is not used in its place either. It is nebula's intent, whereas
/// `from=` is what this lighthouse actually received the packet from, and the
/// question here is which source port the NAT really handed out. The roamed-to
/// address shows up in the next `from=` line within seconds anyway, because a
/// node that just roamed is by definition talking.
///
/// Values may or may not be quoted, so quotes are stripped rather than required.
pub fn parse_line(line: &str) -> Option<LighthouseSample> {
    let cert_name = field(line, "certName=")?;
    let address = field(line, "from=")?;
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

/// One node's overlay address as the lighthouse sees it.
///
/// Unlike a contention sample this needs no source address, so heartbeat and
/// teardown lines count too. That is the point: the roster doubles as the
/// liveness signal clients cannot produce themselves, and restricting it to
/// handshakes would blind it to a node that is connected and simply quiet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterEntry {
    pub cert_name: String,
    pub overlay: String,
    /// The line's own timestamp, not the moment it was read.
    pub seen_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterHost {
    pub cert_name: String,
    pub overlay: String,
    /// Last handshake, roam or teardown involving this node. Deliberately not a
    /// liveness signal: nebula logs state *changes*, so a tunnel that has been
    /// up for a day is silent while a node stuck in a handshake loop is the
    /// noisiest thing in the log. Kept as context for the port-contention view.
    pub last_activity_at: i64,
    /// When the lighthouse last probed this node, and the round trip it got.
    /// `probed_at: None` means never probed; `rtt_us: None` with a `probed_at`
    /// means the probe ran and nothing came back.
    pub probed_at: Option<i64>,
    pub rtt_us: Option<i64>,
}

impl RosterHost {
    pub fn reachable(&self) -> Option<bool> {
        self.probed_at.map(|_| self.rtt_us.is_some())
    }
}

/// Extracts `certName` and the node's overlay address from one log line.
pub fn parse_roster_line(line: &str) -> Option<RosterEntry> {
    let cert_name = field(line, "certName=")?;
    // Nebula declares this field as a list. Every observed line carries exactly
    // one address, but a node with several overlay addresses would be reachable
    // at any of them, so the first is as good a probe target as any.
    let overlay = field(line, "vpnAddrs=")?
        .split_whitespace()
        .next()?
        .to_string();
    if cert_name.is_empty() || overlay.is_empty() {
        return None;
    }
    Some(RosterEntry {
        cert_name,
        overlay,
        seen_at: line_time(line),
    })
}

/// Reads the RFC3339 `time=` field nebula stamps on every line.
///
/// Using it rather than the moment of ingestion matters on the first read of a
/// log file: the entire backlog would otherwise be stamped "now" and every
/// long-dead host would be reported as just seen.
pub fn line_time(line: &str) -> Option<i64> {
    let start = line.find("time=\"")? + "time=\"".len();
    let value = line[start..].split('"').next()?;
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|stamp| stamp.timestamp())
}

pub fn parse_roster(text: &str) -> Vec<RosterEntry> {
    text.lines().filter_map(parse_roster_line).collect()
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
            ON lighthouse_observation(bucket_at);
        CREATE TABLE IF NOT EXISTS lighthouse_host (
            cert_name TEXT PRIMARY KEY,
            overlay_addr TEXT NOT NULL,
            last_activity_at INTEGER NOT NULL,
            probed_at INTEGER,
            rtt_us INTEGER
        );
        CREATE TABLE IF NOT EXISTS lighthouse_probe_bucket (
            cert_name TEXT NOT NULL,
            bucket_at INTEGER NOT NULL,
            samples INTEGER NOT NULL,
            ok_samples INTEGER NOT NULL,
            rtt_min_us INTEGER,
            rtt_max_us INTEGER,
            rtt_sum_us INTEGER,
            PRIMARY KEY (cert_name, bucket_at)
        );
        CREATE INDEX IF NOT EXISTS idx_lighthouse_probe_bucket
            ON lighthouse_probe_bucket(bucket_at);",
    )
}

/// Upserts the roster, keeping the newest sighting per node.
///
/// `last_activity_at` only ever moves forward: a batch may contain lines in any
/// order, and re-reading an old file must not drag a node's liveness backwards.
pub fn record_roster(
    connection: &Connection,
    entries: &[RosterEntry],
    fallback_at: i64,
) -> rusqlite::Result<()> {
    for entry in entries {
        connection.execute(
            "INSERT INTO lighthouse_host (cert_name, overlay_addr, last_activity_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(cert_name) DO UPDATE SET
               overlay_addr = excluded.overlay_addr,
               last_activity_at = MAX(last_activity_at, excluded.last_activity_at)",
            rusqlite::params![
                entry.cert_name,
                entry.overlay,
                entry.seen_at.unwrap_or(fallback_at)
            ],
        )?;
    }
    Ok(())
}

/// The lighthouse never handshakes with itself, so it is absent from its own
/// log and has to be announced explicitly. It is alive by definition whenever
/// this collector is running, so its sighting is refreshed on every tick.
pub fn register_self(
    connection: &Connection,
    cert_name: &str,
    overlay: &str,
    at: i64,
) -> rusqlite::Result<()> {
    if cert_name.is_empty() || overlay.is_empty() {
        return Ok(());
    }
    connection.execute(
        "INSERT INTO lighthouse_host (cert_name, overlay_addr, last_activity_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(cert_name) DO UPDATE SET
           overlay_addr = excluded.overlay_addr,
           last_activity_at = excluded.last_activity_at",
        rusqlite::params![cert_name, overlay, at],
    )?;
    Ok(())
}

pub fn hosts(connection: &Connection) -> rusqlite::Result<Vec<RosterHost>> {
    let mut statement = connection.prepare(
        "SELECT cert_name, overlay_addr, last_activity_at, probed_at, rtt_us
         FROM lighthouse_host ORDER BY cert_name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(RosterHost {
            cert_name: row.get(0)?,
            overlay: row.get(1)?,
            last_activity_at: row.get(2)?,
            probed_at: row.get(3)?,
            rtt_us: row.get(4)?,
        })
    })?;
    rows.collect()
}

/// One node's probe outcomes folded into a single five-minute bucket, from the
/// lighthouse's vantage point.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeBucket {
    pub cert_name: String,
    pub bucket_at: i64,
    pub samples: i64,
    pub ok_samples: i64,
    pub rtt_min_us: Option<i64>,
    pub rtt_max_us: Option<i64>,
    pub rtt_sum_us: Option<i64>,
}

/// Stores one probe outcome. A miss is written just as deliberately as a hit:
/// leaving `rtt_us` alone on failure would keep serving the last good round
/// trip and make an unreachable node look merely stale.
///
/// The outcome lands in two places. `lighthouse_host` keeps only the latest
/// value, which answers "is it up right now"; the bucket table keeps the whole
/// series, which answers "was it up last night". Only the second question can
/// be asked about a link the asker is not on: a client watching the mesh
/// measures its own tunnels, so an outage between the lighthouse and a node is
/// visible from nowhere else, and a client that was asleep at the time cannot
/// reconstruct it afterwards from anything but this table.
pub fn record_probe(
    connection: &Connection,
    cert_name: &str,
    at: i64,
    rtt_us: Option<u32>,
) -> rusqlite::Result<()> {
    connection.execute(
        "UPDATE lighthouse_host SET probed_at = ?2, rtt_us = ?3 WHERE cert_name = ?1",
        rusqlite::params![cert_name, at, rtt_us.map(i64::from)],
    )?;
    let rtt = rtt_us.map(i64::from);
    connection.execute(
        "INSERT INTO lighthouse_probe_bucket
           (cert_name, bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us)
         VALUES (?1, ?2, 1, ?3, ?4, ?4, ?4)
         ON CONFLICT(cert_name, bucket_at) DO UPDATE SET
           samples = samples + 1,
           ok_samples = ok_samples + excluded.ok_samples,
           rtt_min_us = MIN(COALESCE(rtt_min_us, excluded.rtt_min_us),
                            COALESCE(excluded.rtt_min_us, rtt_min_us)),
           rtt_max_us = MAX(COALESCE(rtt_max_us, excluded.rtt_max_us),
                            COALESCE(excluded.rtt_max_us, rtt_max_us)),
           rtt_sum_us = CASE WHEN excluded.rtt_sum_us IS NULL THEN rtt_sum_us
                             ELSE COALESCE(rtt_sum_us, 0) + excluded.rtt_sum_us END",
        rusqlite::params![
            cert_name,
            bucket_start(at as f64),
            i64::from(rtt.is_some()),
            rtt
        ],
    )?;
    Ok(())
}

pub fn probe_history(connection: &Connection, since: i64) -> rusqlite::Result<Vec<ProbeBucket>> {
    let mut statement = connection.prepare(
        "SELECT cert_name, bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us
         FROM lighthouse_probe_bucket WHERE bucket_at >= ?1
         ORDER BY cert_name, bucket_at",
    )?;
    let rows = statement.query_map([since], |row| {
        Ok(ProbeBucket {
            cert_name: row.get(0)?,
            bucket_at: row.get(1)?,
            samples: row.get(2)?,
            ok_samples: row.get(3)?,
            rtt_min_us: row.get(4)?,
            rtt_max_us: row.get(5)?,
            rtt_sum_us: row.get(6)?,
        })
    })?;
    rows.collect()
}

/// Pings every node on the roster and records the outcome.
///
/// This is the liveness signal the log cannot provide, and it is why the
/// lighthouse is worth asking at all: a node it can reach but the client cannot
/// is a broken tunnel, while a node neither can reach is simply down.
pub fn probe_roster(connection: &Connection, timeout: Duration) -> rusqlite::Result<usize> {
    let roster = hosts(connection)?;
    let mut probed = 0;
    for (index, host) in roster.iter().enumerate() {
        let Ok(address) = host.overlay.parse::<std::net::Ipv4Addr>() else {
            continue;
        };
        // Sequence numbers only have to distinguish this sweep's replies from
        // each other; a stale reply carrying an earlier host's number is
        // rejected by the payload token anyway.
        let rtt = crate::icmp::ping(address, index as u16 + 1, timeout);
        record_probe(connection, &host.cert_name, crate::util::epoch_now(), rtt)?;
        probed += 1;
    }
    Ok(probed)
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

/// Per WAN IP: the default-port holder with its packet count, and the nodes
/// whose port was rewritten.
type WanContention<'a> = (Option<(&'a str, i64)>, Vec<&'a str>);

pub fn contention(rows: &[LighthouseRow], default_port: u16) -> Vec<ContentionView> {
    let mut by_wan: HashMap<&str, WanContention> = HashMap::new();
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
    /// This lighthouse's own `certName` and overlay address. Absent from its own
    /// log, so without these two the roster is short exactly one node — the one
    /// every other node depends on.
    pub self_name: Option<String>,
    pub self_overlay: Option<String>,
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
                    return Err(std::io::Error::other(format!(
                        "journalctl -u {unit} failed"
                    )));
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

pub fn snapshot_json(
    rows: &[LighthouseRow],
    roster: &[RosterHost],
    default_port: u16,
    now: i64,
) -> String {
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
    let hosts = roster
        .iter()
        .map(|host| {
            let optional = |value: Option<i64>| match value {
                Some(value) => value.to_string(),
                None => "null".to_string(),
            };
            format!(
                r#"{{"name":{},"overlay":{},"last_activity_at":{},"probed_at":{},"rtt_us":{}}}"#,
                serde_json::Value::String(host.cert_name.clone()),
                serde_json::Value::String(host.overlay.clone()),
                host.last_activity_at,
                optional(host.probed_at),
                optional(host.rtt_us)
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"schema_version":2,"generated_at":{now},"default_port":{default_port},"hosts":[{hosts}],"wan":[{wan}]}}"#
    )
}

/// How far back `/history` reaches when the request does not say.
const DEFAULT_HISTORY_WINDOW_S: i64 = 24 * 60 * 60;

/// The furthest back it will go when the request does say. A cap rather than
/// trust: the response is built in memory, and one node-week is already ~2000
/// buckets.
const MAX_HISTORY_WINDOW_S: i64 = 30 * 24 * 60 * 60;

/// `Some(window_seconds)` for a history request, `None` for anything else.
///
/// History is a separate document rather than a field on the roster because the
/// roster is polled every thirty seconds by every client, and a day of buckets
/// per node would make that poll two orders of magnitude heavier for data
/// nobody reads until something breaks.
pub fn history_window(target: &str) -> Option<i64> {
    let (path, query) = match target.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (target, None),
    };
    if path != "/history" {
        return None;
    }
    let requested = query
        .and_then(|query| {
            query
                .split('&')
                .find_map(|pair| pair.strip_prefix("window="))
        })
        .and_then(|value| value.parse::<i64>().ok());
    Some(
        requested
            .unwrap_or(DEFAULT_HISTORY_WINDOW_S)
            .clamp(BUCKET_WIDTH_S as i64, MAX_HISTORY_WINDOW_S),
    )
}

/// Serialises the per-node probe series.
///
/// Buckets are arrays rather than objects: a week of one node is ~2016 of them,
/// and repeating six key names on every row triples the document for nothing a
/// reader gains. `fields` names the order so the shape stays self-describing.
pub fn probe_history_json(buckets: &[ProbeBucket], since: i64, now: i64) -> String {
    let optional = |value: Option<i64>| match value {
        Some(value) => value.to_string(),
        None => "null".to_string(),
    };
    let mut hosts: Vec<String> = Vec::new();
    let mut index = 0;
    while index < buckets.len() {
        let name = buckets[index].cert_name.clone();
        let mut rows: Vec<String> = Vec::new();
        while index < buckets.len() && buckets[index].cert_name == name {
            let bucket = &buckets[index];
            rows.push(format!(
                "[{},{},{},{},{},{}]",
                bucket.bucket_at,
                bucket.samples,
                bucket.ok_samples,
                optional(bucket.rtt_min_us),
                optional(bucket.rtt_max_us),
                optional(bucket.rtt_sum_us)
            ));
            index += 1;
        }
        hosts.push(format!(
            r#"{{"name":{},"buckets":[{}]}}"#,
            serde_json::Value::String(name),
            rows.join(",")
        ));
    }
    format!(
        r#"{{"schema_version":1,"generated_at":{now},"since":{since},"bucket_width_s":{},"fields":["bucket_at","samples","ok_samples","rtt_min_us","rtt_max_us","rtt_sum_us"],"hosts":[{}]}}"#,
        BUCKET_WIDTH_S as i64,
        hosts.join(",")
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
    spawn_prober(database, config.interval);
    let mut reader = LogReader::new(config.source.clone());
    let mut last_collect = Instant::now()
        .checked_sub(config.interval)
        .unwrap_or_else(Instant::now);
    let mut window = BOOTSTRAP_WINDOW;

    loop {
        if last_collect.elapsed() >= config.interval {
            if let (Some(name), Some(overlay)) = (&config.self_name, &config.self_overlay) {
                let _ = register_self(&connection, name, overlay, crate::util::epoch_now());
            }
            match reader.read_new(window) {
                Ok(text) => {
                    let now = crate::util::epoch_now();
                    // Source ports are bucketed by ingest time, so the bootstrap
                    // pass must not feed them: a day of history would collapse
                    // into the current five-minute bucket and report a burst of
                    // contention that never happened. Discovering *who exists*
                    // is the only thing that read is for.
                    if window != BOOTSTRAP_WINDOW {
                        let samples = parse_batch(&text);
                        if !samples.is_empty() {
                            let _ = record(&connection, &samples, now as f64);
                        }
                    }
                    let entries = parse_roster(&text);
                    if !entries.is_empty() {
                        let _ = record_roster(&connection, &entries, now);
                    }
                    window = config.interval;
                }
                // A transient read failure must not kill the collector; the next
                // tick retries and the endpoint keeps serving what is stored.
                // The window stays wide until one read succeeds, so a lighthouse
                // that starts before journald is ready still gets its history.
                Err(error) => eprintln!("lighthouse: log read failed: {error}"),
            }
            last_collect = Instant::now();
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                let now = crate::util::epoch_now();
                let target = request_target(&mut stream).unwrap_or_default();
                let body = match history_window(&target) {
                    Some(window) => {
                        let since = bucket_start((now - window) as f64);
                        let buckets = probe_history(&connection, since).unwrap_or_default();
                        probe_history_json(&buckets, since, now)
                    }
                    None => {
                        let stored = rows(&connection, 0).unwrap_or_default();
                        let roster = hosts(&connection).unwrap_or_default();
                        snapshot_json(&stored, &roster, config.default_port, now)
                    }
                };
                let _ = respond(stream, &body);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(error) => return Err(error.into()),
        }
    }
}

/// How far back the first journal read reaches.
///
/// The roster is built from state-change lines, so the healthiest nodes are the
/// slowest to appear: a stable tunnel logs nothing, while a node stuck in a
/// handshake loop shows up within seconds. Starting from a bare interval would
/// therefore populate the roster with the broken nodes first and leave the
/// working ones missing.
///
/// A week rather than a day because a day is measurably too short: on the mesh
/// this was built for, a NAS held one tunnel open for 25 hours without logging a
/// line and was missing from the roster entirely. The window has to outlast the
/// quietest healthy node, not the average one.
///
/// Re-reading history is free: `last_activity_at` comes from each line's own
/// timestamp, so a wider window cannot misdate anything. Only the journal source
/// needs this — a file reader already starts at offset zero.
const BOOTSTRAP_WINDOW: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// How long a single node gets to answer. Two seconds covers the ~220 ms
/// intercontinental hops on this mesh with room to spare, without letting one
/// dead node stretch the sweep.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Runs the ICMP sweep on its own thread with its own connection.
///
/// It cannot share the collector's loop: a sweep of a mesh where several nodes
/// are down costs seconds of timeouts, and the HTTP endpoint has to keep
/// answering throughout. WAL plus the busy timeout is what makes the second
/// writer safe, the same way every other thread here gets its own connection.
fn spawn_prober(database: &Path, interval: Duration) {
    let database = database.to_path_buf();
    std::thread::spawn(move || {
        if !crate::icmp::available() {
            // Saying so once beats reporting the entire mesh as unreachable.
            eprintln!(
                "lighthouse: no ICMP socket available; reachability will stay unknown. \
                 Grant CAP_NET_RAW or widen net.ipv4.ping_group_range."
            );
            return;
        }
        let connection = match crate::source::local::db::open_db(&database) {
            Ok(connection) => connection,
            Err(error) => {
                eprintln!("lighthouse: prober cannot open the database: {error}");
                return;
            }
        };
        loop {
            if let Err(error) = probe_roster(&connection, PROBE_TIMEOUT) {
                eprintln!("lighthouse: probe sweep failed: {error}");
            }
            std::thread::sleep(interval);
        }
    });
}

/// Reads the request line and returns its target, e.g. `/history?window=86400`.
///
/// `None` for a request that never arrives or does not parse; the caller serves
/// the roster in that case, which is what this endpoint answered to every
/// request before history existed.
fn request_target(stream: &mut TcpStream) -> Option<String> {
    let mut buffer = [0u8; 1024];
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let read = stream.read(&mut buffer).ok()?;
    let text = String::from_utf8_lossy(&buffer[..read]);
    let mut fields = text.lines().next()?.split_whitespace();
    let _method = fields.next()?;
    Some(fields.next()?.to_string())
}

fn respond(mut stream: TcpStream, body: &str) -> std::io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
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

        let unquoted = "level=info certName=MBA-M2 from=223.95.78.14:61571";
        assert_eq!(
            parse_line(unquoted),
            Some(sample("MBA-M2", "223.95.78.14", 61571))
        );
    }

    /// Verbatim roam line from the Bandwagon2 lighthouse. `udpAddr` here is the
    /// address WSL just left and `newAddr` the one it moved to, so reading either
    /// would file this node under a port it no longer holds — or under one this
    /// lighthouse has not yet received a packet from. The roamed-to address
    /// arrives on the next `from=` line regardless.
    #[test]
    fn a_roam_line_yields_no_contention_sample() {
        let roam = r#"time="2026-07-29T10:32:00+08:00" level=info msg="Host roamed to new udp ip/port." certName=WSL localIndex=944200205 newAddr="223.95.78.14:2442" remoteIndex=536779223 udpAddr="223.95.78.14:2019" vpnAddrs="[192.168.100.26]""#;
        assert_eq!(parse_line(roam), None);
        // The same line still names the node and its overlay address, so the
        // roster keeps counting it as seen.
        assert_eq!(
            parse_roster_line(roam).map(|entry| entry.overlay),
            Some("192.168.100.26".to_string())
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
        let roster = vec![
            RosterHost {
                cert_name: "DS925".into(),
                overlay: "192.168.100.125".into(),
                last_activity_at: 1_699_999_900,
                probed_at: Some(1_700_000_000),
                rtt_us: Some(211_517),
            },
            RosterHost {
                cert_name: "iMac".into(),
                overlay: "192.168.100.12".into(),
                last_activity_at: 1_699_000_000,
                probed_at: Some(1_700_000_000),
                rtt_us: None,
            },
        ];
        let body = snapshot_json(&rows, &roster, 4242, 1_700_000_000);
        let parsed: serde_json::Value = serde_json::from_str(&body).expect("valid JSON");
        assert_eq!(parsed["default_port"], 4242);
        assert_eq!(parsed["wan"][0]["wan_ip"], "123.158.49.251");
        assert_eq!(parsed["wan"][0]["holder"], "DS925");
        assert_eq!(parsed["wan"][0]["rewritten"][0], "MBA-M2");
        assert_eq!(parsed["hosts"][0]["name"], "DS925");
        assert_eq!(parsed["hosts"][0]["overlay"], "192.168.100.125");
        assert_eq!(parsed["hosts"][0]["last_activity_at"], 1_699_999_900_i64);
        assert_eq!(parsed["hosts"][0]["rtt_us"], 211_517);
        // An unreachable node must be a probed miss, not an absent measurement.
        assert_eq!(parsed["hosts"][1]["probed_at"], 1_700_000_000_i64);
        assert!(parsed["hosts"][1]["rtt_us"].is_null());
    }

    #[test]
    fn snapshot_json_survives_an_empty_database_and_absent_holder() {
        let empty: serde_json::Value =
            serde_json::from_str(&snapshot_json(&[], &[], 4242, 1)).expect("valid JSON");
        assert_eq!(empty["wan"].as_array().map(Vec::len), Some(0));
        assert_eq!(empty["hosts"].as_array().map(Vec::len), Some(0));

        let rows = vec![LighthouseRow {
            bucket_at: 0,
            cert_name: "Mini-M4".into(),
            wan_ip: "223.95.78.14".into(),
            source_port: 53818,
            packets: 4,
        }];
        let parsed: serde_json::Value =
            serde_json::from_str(&snapshot_json(&rows, &[], 4242, 1)).expect("valid JSON");
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

    /// Verbatim lines from the Bandwagon2 lighthouse. The second one carries no
    /// `from=`, which is the whole reason the roster is parsed separately: a
    /// connected but quiet node still has to count as seen.
    #[test]
    fn roster_reads_overlay_and_the_line_s_own_timestamp() {
        let handshake = r#"Jul 29 14:05:54 sweet-node-2 nebula[394263]: time="2026-07-29T14:05:54+08:00" level=info msg="Handshake message received" certName=WSL certVersion=1 from="124.90.54.149:4242" vpnAddrs="[192.168.100.26]""#;
        assert_eq!(
            parse_roster_line(handshake),
            Some(RosterEntry {
                cert_name: "WSL".into(),
                overlay: "192.168.100.26".into(),
                seen_at: Some(1_785_305_154),
            })
        );

        let heartbeat = r#"Jul 29 14:06:04 sweet-node-2 nebula[394263]: time="2026-07-29T14:06:04+08:00" level=info msg="Tunnel status" certName=WSL localIndex=6132250 tunnelCheck="map[method:active state:dead]" vpnAddrs="[192.168.100.26]""#;
        assert_eq!(
            parse_roster_line(heartbeat).and_then(|entry| entry.seen_at),
            Some(1_785_305_164)
        );
    }

    /// The lighthouse's own line uses `vpnNetworks` with a CIDR suffix, so it
    /// must not be mistaken for a roster entry — that is what `register_self`
    /// is for. Handshake timeouts carry no `certName` at all.
    #[test]
    fn roster_rejects_lines_without_a_usable_overlay() {
        let myself = r#"time="2026-07-28T10:51:26+08:00" level=error msg="Refusing to handshake with myself" certName=Bandwagon2 from="107.182.186.158:4242" vpnNetworks="[192.168.100.200/24]""#;
        assert!(parse_roster_line(myself).is_none());
        assert!(parse_roster_line(r#"msg="Handshake timed out" udpAddr="1.2.3.4:4242""#).is_none());
        assert!(parse_roster_line("").is_none());
    }

    /// A line with no parsable timestamp still counts, but only at ingest time.
    #[test]
    fn roster_falls_back_to_ingest_time() {
        let entry = parse_roster_line(r#"certName=3B vpnAddrs="[192.168.100.7]""#).unwrap();
        assert_eq!(entry.seen_at, None);

        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        record_roster(&connection, &[entry], 1_785_000_000).unwrap();
        assert_eq!(
            hosts(&connection).unwrap()[0].last_activity_at,
            1_785_000_000
        );
    }

    /// Re-reading an old file must not drag a node's liveness backwards, or a
    /// log rotation would report every host as long gone.
    #[test]
    fn roster_last_seen_only_moves_forward() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        let entry = |seen: i64| RosterEntry {
            cert_name: "WSL".into(),
            overlay: "192.168.100.26".into(),
            seen_at: Some(seen),
        };
        record_roster(&connection, &[entry(1_785_305_164)], 0).unwrap();
        record_roster(&connection, &[entry(1_785_000_000)], 0).unwrap();

        let stored = hosts(&connection).unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].last_activity_at, 1_785_305_164);
        assert_eq!(stored[0].overlay, "192.168.100.26");
    }

    /// The lighthouse is alive by definition while the collector runs, so its
    /// own sighting is overwritten rather than kept at the maximum.
    #[test]
    fn self_registration_refreshes_rather_than_accumulates() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        register_self(&connection, "Bandwagon2", "192.168.100.200", 1_785_000_000).unwrap();
        register_self(&connection, "Bandwagon2", "192.168.100.200", 1_785_305_164).unwrap();
        register_self(&connection, "", "192.168.100.201", 1).unwrap();

        let stored = hosts(&connection).unwrap();
        assert_eq!(stored.len(), 1, "an unnamed lighthouse must not be stored");
        assert_eq!(stored[0].cert_name, "Bandwagon2");
        assert_eq!(stored[0].last_activity_at, 1_785_305_164);
    }

    /// The three states a client has to tell apart, and the fourth — never
    /// probed — that must not be mistaken for any of them.
    #[test]
    fn probe_results_distinguish_unreachable_from_unprobed() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        let seen = |name: &str, overlay: &str| RosterEntry {
            cert_name: name.into(),
            overlay: overlay.into(),
            seen_at: Some(1_785_000_000),
        };
        record_roster(
            &connection,
            &[
                seen("Mini-M4", "192.168.100.24"),
                seen("iMac", "192.168.100.12"),
                seen("WSL", "192.168.100.26"),
            ],
            0,
        )
        .unwrap();

        record_probe(&connection, "Mini-M4", 1_785_305_164, Some(1_390)).unwrap();
        record_probe(&connection, "iMac", 1_785_305_164, None).unwrap();

        let by_name: HashMap<String, RosterHost> = hosts(&connection)
            .unwrap()
            .into_iter()
            .map(|host| (host.cert_name.clone(), host))
            .collect();
        assert_eq!(by_name["Mini-M4"].reachable(), Some(true));
        assert_eq!(by_name["Mini-M4"].rtt_us, Some(1_390));
        assert_eq!(by_name["iMac"].reachable(), Some(false));
        assert_eq!(by_name["WSL"].reachable(), None, "never probed is not down");
    }

    /// A node that stops answering must lose its last good round trip, or the
    /// view keeps showing a latency for something it can no longer reach.
    #[test]
    fn a_failed_probe_clears_the_previous_round_trip() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        record_roster(
            &connection,
            &[RosterEntry {
                cert_name: "DS925".into(),
                overlay: "192.168.100.125".into(),
                seen_at: Some(1_785_000_000),
            }],
            0,
        )
        .unwrap();

        record_probe(&connection, "DS925", 1_785_000_100, Some(211_517)).unwrap();
        record_probe(&connection, "DS925", 1_785_000_200, None).unwrap();

        let host = hosts(&connection).unwrap().remove(0);
        assert_eq!(host.rtt_us, None);
        assert_eq!(host.probed_at, Some(1_785_000_200));
        assert_eq!(host.reachable(), Some(false));
        // The log-derived timestamp is a separate axis and must not move.
        assert_eq!(host.last_activity_at, 1_785_000_000);
    }

    /// The outage this whole table exists for: the lighthouse could not reach
    /// DS925 for a stretch of the night. The current-state row keeps only the
    /// last probe, so without the bucket series that stretch leaves no trace
    /// anywhere — least of all on a client that was asleep while it happened.
    #[test]
    fn probe_history_keeps_an_outage_the_current_row_forgets() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        record_roster(
            &connection,
            &[RosterEntry {
                cert_name: "DS925".into(),
                overlay: "192.168.100.125".into(),
                seen_at: Some(1_785_000_000),
            }],
            0,
        )
        .unwrap();

        // 02:00–02:05 healthy, 02:05–02:10 nothing through, then healthy again.
        record_probe(&connection, "DS925", 1_785_000_000, Some(199_000)).unwrap();
        record_probe(&connection, "DS925", 1_785_000_030, Some(221_000)).unwrap();
        record_probe(&connection, "DS925", 1_785_000_300, None).unwrap();
        record_probe(&connection, "DS925", 1_785_000_330, None).unwrap();
        record_probe(&connection, "DS925", 1_785_000_600, Some(205_000)).unwrap();

        let history = probe_history(&connection, 0).unwrap();
        assert_eq!(history.len(), 3, "three five-minute buckets");
        assert_eq!(history[0].bucket_at, 1_785_000_000);
        assert_eq!(history[0].samples, 2);
        assert_eq!(history[0].ok_samples, 2);
        assert_eq!(history[0].rtt_min_us, Some(199_000));
        assert_eq!(history[0].rtt_max_us, Some(221_000));
        assert_eq!(history[0].rtt_sum_us, Some(420_000));

        let outage = &history[1];
        assert_eq!(outage.bucket_at, 1_785_000_300);
        assert_eq!(outage.samples, 2, "the probes ran");
        assert_eq!(outage.ok_samples, 0, "and none of them came back");
        assert_eq!(
            outage.rtt_min_us, None,
            "a lost bucket must carry no latency at all, or it plots as 0ms"
        );

        // The row a client polls has already moved on; only the series remembers.
        assert_eq!(hosts(&connection).unwrap()[0].rtt_us, Some(205_000));
    }

    /// A window boundary must not swallow the buckets on the far side of it.
    #[test]
    fn probe_history_honours_the_requested_window() {
        let connection = Connection::open_in_memory().unwrap();
        create_schema(&connection).unwrap();
        record_roster(
            &connection,
            &[RosterEntry {
                cert_name: "DS925".into(),
                overlay: "192.168.100.125".into(),
                seen_at: Some(1),
            }],
            0,
        )
        .unwrap();
        record_probe(&connection, "DS925", 1_785_000_000, Some(1)).unwrap();
        record_probe(&connection, "DS925", 1_785_000_600, Some(2)).unwrap();

        assert_eq!(probe_history(&connection, 1_785_000_300).unwrap().len(), 1);
        assert_eq!(probe_history(&connection, 1_785_000_000).unwrap().len(), 2);
    }

    #[test]
    fn history_requests_are_told_apart_from_roster_requests() {
        assert_eq!(history_window("/"), None);
        assert_eq!(history_window(""), None);
        assert_eq!(history_window("/v1/status"), None);
        assert_eq!(history_window("/history"), Some(DEFAULT_HISTORY_WINDOW_S));
        assert_eq!(history_window("/history?window=21600"), Some(21_600));
        assert_eq!(
            history_window("/history?foo=1&window=21600"),
            Some(21_600),
            "the window may not be the first parameter"
        );
        // Garbage and out-of-range values are clamped rather than refused: a
        // client asking for too much still deserves an answer.
        assert_eq!(
            history_window("/history?window=abc"),
            Some(DEFAULT_HISTORY_WINDOW_S)
        );
        assert_eq!(history_window("/history?window=0"), Some(300));
        assert_eq!(
            history_window("/history?window=99999999"),
            Some(MAX_HISTORY_WINDOW_S)
        );
    }

    #[test]
    fn history_json_groups_buckets_under_each_node() {
        let bucket = |name: &str, at: i64, ok: i64, rtt: Option<i64>| ProbeBucket {
            cert_name: name.into(),
            bucket_at: at,
            samples: 1,
            ok_samples: ok,
            rtt_min_us: rtt,
            rtt_max_us: rtt,
            rtt_sum_us: rtt,
        };
        let body = probe_history_json(
            &[
                bucket("Bandwagon2", 1_785_000_000, 1, Some(90)),
                bucket("DS925", 1_785_000_000, 1, Some(199_000)),
                bucket("DS925", 1_785_000_300, 0, None),
            ],
            1_785_000_000,
            1_785_000_900,
        );
        let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(parsed["bucket_width_s"], 300);
        assert_eq!(parsed["since"], 1_785_000_000_i64);
        assert_eq!(parsed["hosts"].as_array().unwrap().len(), 2);
        assert_eq!(parsed["hosts"][1]["name"], "DS925");
        let buckets = parsed["hosts"][1]["buckets"].as_array().unwrap();
        assert_eq!(buckets.len(), 2);
        assert_eq!(buckets[1][0], 1_785_000_300_i64);
        assert_eq!(buckets[1][2], 0, "ok_samples");
        assert!(buckets[1][3].is_null(), "a lost bucket carries no latency");
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
