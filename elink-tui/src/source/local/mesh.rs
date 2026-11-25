//! The nebula overlay as this node sees it.
//!
//! Deliberately separate from the usage cluster. The two answer different
//! questions about different sets of machines: the cluster is "which hosts
//! share token usage with me" (a handful that run this app), the mesh is "which
//! devices are on the VPN and can I reach them" (every device with a
//! certificate, most of which will never run this app). Measuring the mesh
//! through cluster synchronization made the smaller set stand in for the larger
//! one and quietly measured LAN paths instead of tunnels.
//!
//! Two vantage points are combined. This node pings each overlay address, and
//! the lighthouse publishes what it can reach. Neither alone can separate "that
//! device is off" from "only my tunnel to it is broken", and that distinction
//! is the difference between a diagnosis and a shrug.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::time::Duration;

use rusqlite::Connection;

/// Matches the other probe tables so every time axis in the app lines up.
pub const BUCKET_WIDTH_S: f64 = 300.0;

/// One node has to answer within this long. Generous on purpose: an
/// intercontinental hop on this mesh runs past 220 ms, and a timeout that
/// clipped it would report a working tunnel as down.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// A node as published by the lighthouse.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterHost {
    pub name: String,
    pub overlay: Ipv4Addr,
    /// Last handshake or teardown the lighthouse logged. Context only — nebula
    /// logs state changes, so silence here means a stable tunnel, not absence.
    pub last_activity_at: i64,
    /// What the lighthouse's own probe found. `None` means it has not probed
    /// (or cannot), which is not the same as a failed probe.
    pub lighthouse_reachable: Option<bool>,
    pub lighthouse_rtt_us: Option<i64>,
}

/// What this node concludes about a peer, given both vantage points.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshState {
    /// This node reached it.
    Online,
    /// The lighthouse reached it and this node could not: the device is up and
    /// the tunnel between here and there is what is broken.
    TunnelDown,
    /// Neither vantage point reached it.
    Offline,
    /// This node could not reach it and the lighthouse has no opinion, so there
    /// is nothing to attribute the failure to yet.
    Unreachable,
}

impl MeshState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Online => "online",
            Self::TunnelDown => "tunnel_down",
            Self::Offline => "offline",
            Self::Unreachable => "unreachable",
        }
    }
}

/// Combines the local probe with the lighthouse's.
///
/// A local success ends the question: whatever the lighthouse thinks, this node
/// can reach the peer, which is what the user is actually asking about.
pub fn classify(local_rtt_us: Option<u32>, lighthouse_reachable: Option<bool>) -> MeshState {
    match (local_rtt_us, lighthouse_reachable) {
        (Some(_), _) => MeshState::Online,
        (None, Some(true)) => MeshState::TunnelDown,
        (None, Some(false)) => MeshState::Offline,
        (None, None) => MeshState::Unreachable,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MeshBucket {
    pub host_name: String,
    pub bucket_at: f64,
    pub samples: i64,
    pub ok_samples: i64,
    pub rtt_min_us: Option<i64>,
    pub rtt_max_us: Option<i64>,
    pub rtt_sum_us: Option<i64>,
}

impl MeshBucket {
    pub fn rtt_avg_us(&self) -> Option<i64> {
        match (self.ok_samples, self.rtt_sum_us) {
            (ok, Some(sum)) if ok > 0 => Some(sum / ok),
            _ => None,
        }
    }
}

/// Rolled-up view of one node over a window, ready to render.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MeshSummary {
    pub samples: i64,
    pub ok_samples: i64,
    pub rtt_min_us: Option<i64>,
    pub rtt_max_us: Option<i64>,
    pub rtt_sum_us: i64,
}

impl MeshSummary {
    pub fn rtt_avg_us(&self) -> Option<i64> {
        (self.ok_samples > 0).then(|| self.rtt_sum_us / self.ok_samples)
    }

    pub fn lost_samples(&self) -> i64 {
        (self.samples - self.ok_samples).max(0)
    }

    /// Fraction of probes that came back, as a percentage. `None` before the
    /// first probe, so an untested node is not drawn as 0% reachable.
    pub fn reachability_percent(&self) -> Option<f64> {
        (self.samples > 0).then(|| self.ok_samples as f64 * 100.0 / self.samples as f64)
    }
}

pub fn bucket_start(time: f64) -> f64 {
    (time / BUCKET_WIDTH_S).floor() * BUCKET_WIDTH_S
}

pub fn create_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS mesh_probe_bucket (
            host_name TEXT NOT NULL,
            bucket_at REAL NOT NULL,
            samples INTEGER NOT NULL,
            ok_samples INTEGER NOT NULL,
            rtt_min_us INTEGER,
            rtt_max_us INTEGER,
            rtt_sum_us INTEGER,
            PRIMARY KEY (host_name, bucket_at)
        );",
    )
}

/// Records one probe. Row count follows the bucket width rather than the sample
/// count, so like every other table here this needs no pruning.
pub fn record_sample(
    connection: &Connection,
    host_name: &str,
    at: f64,
    rtt_us: Option<u32>,
) -> rusqlite::Result<()> {
    if host_name.is_empty() {
        return Ok(());
    }
    let rtt = rtt_us.map(i64::from);
    connection.execute(
        "INSERT INTO mesh_probe_bucket
           (host_name, bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us)
         VALUES (?1, ?2, 1, ?3, ?4, ?4, ?4)
         ON CONFLICT(host_name, bucket_at) DO UPDATE SET
           samples = samples + 1,
           ok_samples = ok_samples + excluded.ok_samples,
           rtt_min_us = MIN(COALESCE(rtt_min_us, excluded.rtt_min_us),
                            COALESCE(excluded.rtt_min_us, rtt_min_us)),
           rtt_max_us = MAX(COALESCE(rtt_max_us, excluded.rtt_max_us),
                            COALESCE(excluded.rtt_max_us, rtt_max_us)),
           rtt_sum_us = CASE WHEN excluded.rtt_sum_us IS NULL THEN rtt_sum_us
                             ELSE COALESCE(rtt_sum_us, 0) + excluded.rtt_sum_us END",
        rusqlite::params![host_name, bucket_start(at), i64::from(rtt.is_some()), rtt],
    )?;
    Ok(())
}

pub fn buckets(connection: &Connection, since: f64) -> rusqlite::Result<Vec<MeshBucket>> {
    let mut statement = connection.prepare(
        "SELECT host_name, bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us
         FROM mesh_probe_bucket WHERE bucket_at >= ?1 ORDER BY bucket_at",
    )?;
    let rows = statement.query_map([since], |row| {
        Ok(MeshBucket {
            host_name: row.get(0)?,
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

pub fn summaries(
    connection: &Connection,
    since: f64,
) -> rusqlite::Result<HashMap<String, MeshSummary>> {
    let mut summaries: HashMap<String, MeshSummary> = HashMap::new();
    for bucket in buckets(connection, since)? {
        let entry = summaries.entry(bucket.host_name).or_default();
        entry.samples += bucket.samples;
        entry.ok_samples += bucket.ok_samples;
        entry.rtt_sum_us += bucket.rtt_sum_us.unwrap_or(0);
        entry.rtt_min_us = match (entry.rtt_min_us, bucket.rtt_min_us) {
            (Some(current), Some(value)) => Some(current.min(value)),
            (current, value) => current.or(value),
        };
        entry.rtt_max_us = match (entry.rtt_max_us, bucket.rtt_max_us) {
            (Some(current), Some(value)) => Some(current.max(value)),
            (current, value) => current.or(value),
        };
    }
    Ok(summaries)
}

/// Parses the lighthouse's published roster.
///
/// Hosts whose overlay address does not parse are dropped rather than guessed
/// at: a probe needs an address, and inventing one would report a node that
/// does not exist.
pub fn parse_roster(body: &str) -> Vec<RosterHost> {
    let Ok(document) = serde_json::from_str::<serde_json::Value>(body) else {
        return Vec::new();
    };
    let Some(hosts) = document["hosts"].as_array() else {
        return Vec::new();
    };
    hosts
        .iter()
        .filter_map(|host| {
            let name = host["name"].as_str()?.to_string();
            let overlay = host["overlay"].as_str()?.parse().ok()?;
            let probed = host["probed_at"].as_i64();
            let rtt = host["rtt_us"].as_i64();
            Some(RosterHost {
                name,
                overlay,
                last_activity_at: host["last_activity_at"].as_i64().unwrap_or(0),
                lighthouse_reachable: probed.map(|_| rtt.is_some()),
                lighthouse_rtt_us: rtt,
            })
        })
        .collect()
}

/// Fetches the roster over plain HTTP.
///
/// Unauthenticated by design and therefore bound to the overlay on the
/// lighthouse side: the document names every node and its WAN address, so the
/// protection is that only the VPN can reach the port at all.
pub fn fetch_roster(agent: &ureq::Agent, url: &str) -> Option<Vec<RosterHost>> {
    let body = agent.get(url).call().ok()?.into_string().ok()?;
    let roster = parse_roster(&body);
    (!roster.is_empty()).then_some(roster)
}

/// Probes every node on the roster and records the results.
///
/// The local node is not skipped. Pinging our own overlay address exercises the
/// nebula interface itself, and an unreachable local address is a real fault
/// worth surfacing rather than an uninteresting tautology.
pub fn probe_all(
    connection: &Connection,
    roster: &[RosterHost],
    at: f64,
) -> rusqlite::Result<Vec<(String, MeshState, Option<u32>)>> {
    let mut results = Vec::with_capacity(roster.len());
    for (index, host) in roster.iter().enumerate() {
        let rtt = crate::icmp::ping(host.overlay, index as u16 + 1, PROBE_TIMEOUT);
        record_sample(connection, &host.name, at, rtt)?;
        results.push((
            host.name.clone(),
            classify(rtt, host.lighthouse_reachable),
            rtt,
        ));
    }
    Ok(results)
}

/// One node, rolled up and ready to render.
#[derive(Debug, Clone, PartialEq)]
pub struct MeshHostView {
    pub name: String,
    pub overlay: Ipv4Addr,
    pub state: MeshState,
    /// This sweep's own round trip. Distinct from the window average: the point
    /// of a "now" column is that it can disagree with the hour behind it.
    pub latest_rtt_us: Option<u32>,
    pub summary: MeshSummary,
    /// The lighthouse's own round trip, shown when this node cannot reach the
    /// peer: it is the evidence behind calling the tunnel rather than the
    /// device broken.
    pub lighthouse_rtt_us: Option<i64>,
    pub last_activity_at: i64,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct MeshSnapshot {
    pub hosts: Vec<MeshHostView>,
    /// False once a roster fetch has failed; the view keeps serving the last
    /// roster so a lighthouse restart does not blank the mesh.
    pub lighthouse_reachable: bool,
    /// False when no ICMP socket can be opened at all, so the UI can say the
    /// measurement is unavailable rather than draw every node as down.
    pub icmp_available: bool,
    pub updated_at: f64,
}

/// Polls the mesh in the background and publishes a rendered snapshot.
pub struct MeshMonitor {
    snapshot: std::sync::Arc<std::sync::Mutex<MeshSnapshot>>,
}

impl MeshMonitor {
    /// `window_s` is how far back the rendered min/avg/max reaches.
    pub fn spawn(
        database: std::path::PathBuf,
        lighthouse_url: String,
        interval: Duration,
        window_s: i64,
    ) -> Self {
        let snapshot = std::sync::Arc::new(std::sync::Mutex::new(MeshSnapshot {
            icmp_available: crate::icmp::available(),
            ..MeshSnapshot::default()
        }));
        let published = std::sync::Arc::clone(&snapshot);
        std::thread::spawn(move || {
            let Ok(connection) = crate::source::local::db::open_db(&database) else {
                return;
            };
            if create_schema(&connection).is_err() {
                return;
            }
            let agent = ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(5))
                .build();
            let icmp_available = crate::icmp::available();
            let mut roster: Vec<RosterHost> = Vec::new();
            loop {
                let fetched = fetch_roster(&agent, &lighthouse_url);
                let lighthouse_reachable = fetched.is_some();
                if let Some(fetched) = fetched {
                    roster = fetched;
                }
                let now = crate::util::epoch_now() as f64;
                // The state is this sweep's own result, not anything read back
                // out of the buckets: those span five minutes, so a node that
                // dropped a moment ago would still be reported as up.
                let probed: HashMap<String, (MeshState, Option<u32>)> = if icmp_available {
                    probe_all(&connection, &roster, now)
                        .unwrap_or_default()
                        .into_iter()
                        .map(|(name, state, rtt)| (name, (state, rtt)))
                        .collect()
                } else {
                    HashMap::new()
                };
                let window = summaries(&connection, now - window_s as f64).unwrap_or_default();
                let hosts = roster
                    .iter()
                    .map(|host| {
                        let summary = window.get(&host.name).cloned().unwrap_or_default();
                        let (state, latest_rtt_us) = probed
                            .get(&host.name)
                            .copied()
                            .unwrap_or((MeshState::Unreachable, None));
                        MeshHostView {
                            name: host.name.clone(),
                            overlay: host.overlay,
                            state,
                            latest_rtt_us,
                            summary,
                            lighthouse_rtt_us: host.lighthouse_rtt_us,
                            last_activity_at: host.last_activity_at,
                        }
                    })
                    .collect();
                if let Ok(mut guard) = published.lock() {
                    *guard = MeshSnapshot {
                        hosts,
                        lighthouse_reachable,
                        icmp_available,
                        updated_at: now,
                    };
                }
                std::thread::sleep(interval);
            }
        });
        Self { snapshot }
    }

    pub fn snapshot(&self) -> MeshSnapshot {
        self.snapshot
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::local::db::open_temp;

    /// Falls inside the [1_699_999_800, 1_700_000_100) bucket.
    const BASE: f64 = 1_700_000_000.0;

    /// The whole point of asking two vantage points: WSL and iMac look
    /// identical from here, and only the lighthouse separates them.
    #[test]
    fn classification_separates_a_broken_tunnel_from_a_dead_host() {
        assert_eq!(classify(Some(1_390), Some(true)), MeshState::Online);
        assert_eq!(classify(None, Some(true)), MeshState::TunnelDown);
        assert_eq!(classify(None, Some(false)), MeshState::Offline);
        assert_eq!(classify(None, None), MeshState::Unreachable);
    }

    /// Reaching a node the lighthouse cannot is still online: the question is
    /// what *this* node can talk to.
    #[test]
    fn a_local_success_outranks_the_lighthouse() {
        assert_eq!(classify(Some(220), Some(false)), MeshState::Online);
        assert_eq!(classify(Some(220), None), MeshState::Online);
    }

    #[test]
    fn samples_aggregate_into_aligned_buckets() {
        let (connection, _path) = open_temp("mesh-buckets");
        create_schema(&connection).unwrap();
        record_sample(&connection, "Mini-M4", BASE, Some(1_110)).unwrap();
        record_sample(&connection, "Mini-M4", BASE + 50.0, Some(1_390)).unwrap();
        record_sample(&connection, "Mini-M4", BASE + 400.0, Some(9_000)).unwrap();

        let rows = buckets(&connection, BASE - 600.0).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].bucket_at, 1_699_999_800.0);
        assert_eq!(rows[0].samples, 2);
        assert_eq!(rows[0].rtt_min_us, Some(1_110));
        assert_eq!(rows[0].rtt_max_us, Some(1_390));
        assert_eq!(rows[0].rtt_avg_us(), Some(1_250));
        assert_eq!(rows[1].rtt_max_us, Some(9_000));
    }

    /// A window with no successful probe must keep no latency, or the chart
    /// draws a 0 ms line where there was no connectivity at all.
    #[test]
    fn a_fully_failed_bucket_keeps_no_latency() {
        let (connection, _path) = open_temp("mesh-failed");
        create_schema(&connection).unwrap();
        record_sample(&connection, "iMac", BASE, None).unwrap();
        record_sample(&connection, "iMac", BASE + 30.0, None).unwrap();

        let summary = &summaries(&connection, BASE - 600.0).unwrap()["iMac"];
        assert_eq!(summary.samples, 2);
        assert_eq!(summary.ok_samples, 0);
        assert_eq!(summary.rtt_avg_us(), None);
        assert_eq!(summary.lost_samples(), 2);
        assert_eq!(summary.reachability_percent(), Some(0.0));
    }

    /// Both orderings matter: a reversed COALESCE only breaks one of them.
    #[test]
    fn failed_probes_do_not_move_the_latency_bounds() {
        let (connection, _path) = open_temp("mesh-mixed");
        create_schema(&connection).unwrap();
        record_sample(&connection, "fail-first", BASE, None).unwrap();
        record_sample(&connection, "fail-first", BASE + 15.0, Some(2_050)).unwrap();
        record_sample(&connection, "ok-first", BASE, Some(2_050)).unwrap();
        record_sample(&connection, "ok-first", BASE + 15.0, None).unwrap();

        let all = summaries(&connection, BASE - 600.0).unwrap();
        for name in ["fail-first", "ok-first"] {
            let summary = &all[name];
            assert_eq!(summary.samples, 2, "{name}");
            assert_eq!(summary.rtt_min_us, Some(2_050), "{name}");
            assert_eq!(summary.rtt_max_us, Some(2_050), "{name}");
            assert_eq!(summary.reachability_percent(), Some(50.0), "{name}");
        }
    }

    #[test]
    fn an_unprobed_host_has_no_reachability_figure() {
        assert_eq!(MeshSummary::default().reachability_percent(), None);
        assert_eq!(MeshSummary::default().rtt_avg_us(), None);
    }

    /// Verbatim shape of what the deployed lighthouse serves.
    #[test]
    fn roster_parses_every_probe_state() {
        let body = r#"{"schema_version":2,"generated_at":1785314411,"default_port":4242,
            "hosts":[
              {"name":"Mini-M4","overlay":"192.168.100.24","last_activity_at":1785233489,
               "probed_at":1785314400,"rtt_us":1110},
              {"name":"iMac","overlay":"192.168.100.12","last_activity_at":1785288941,
               "probed_at":1785314400,"rtt_us":null},
              {"name":"WSL","overlay":"192.168.100.26","last_activity_at":1785314394,
               "probed_at":null,"rtt_us":null}],
            "wan":[]}"#;
        let roster = parse_roster(body);
        assert_eq!(roster.len(), 3);
        assert_eq!(roster[0].overlay, Ipv4Addr::new(192, 168, 100, 24));
        assert_eq!(roster[0].lighthouse_reachable, Some(true));
        assert_eq!(roster[0].lighthouse_rtt_us, Some(1_110));
        assert_eq!(roster[1].lighthouse_reachable, Some(false));
        assert_eq!(
            roster[2].lighthouse_reachable, None,
            "never probed must not read as unreachable"
        );
    }

    /// A lighthouse that is down, upgrading, or serving something else must not
    /// wipe the mesh view; the caller keeps the last roster instead.
    #[test]
    fn roster_survives_junk_without_inventing_hosts() {
        assert!(parse_roster("not json").is_empty());
        assert!(parse_roster("{}").is_empty());
        assert!(parse_roster(r#"{"hosts":[]}"#).is_empty());
        assert!(
            parse_roster(r#"{"hosts":[{"name":"X","overlay":"not-an-address"}]}"#).is_empty(),
            "a host without a usable address cannot be probed"
        );
        assert_eq!(
            parse_roster(r#"{"hosts":[{"name":"X","overlay":"192.168.100.9"}]}"#).len(),
            1,
            "a roster from an older lighthouse still names its hosts"
        );
    }
}
