//! Link-health observations derived from cluster synchronization.
//!
//! This is the only unbounded time series in `usage.db`, so nothing raw is
//! stored: samples fold into five-minute buckets and state changes become
//! sparse events. Both stay bounded like every other table here, which is why
//! no pruning logic exists.

use rusqlite::Connection;

use super::stun::StunObservation;

/// Key under which the last observed reflexive endpoint is persisted, so a
/// re-dial spanning a restart is still detected.
pub const LAST_ENDPOINT_KEY: &str = "link_last_external_endpoint";

/// Bucket width is tied to the 15-second probe interval (about 20 samples per
/// bucket). Widening the interval requires widening the bucket in step, or
/// min/max start swinging on too few samples.
pub const BUCKET_WIDTH_S: f64 = 300.0;

#[derive(Debug, Clone, PartialEq)]
pub struct LinkProbeBucket {
    pub node_id: String,
    pub bucket_at: f64,
    pub samples: i64,
    pub ok_samples: i64,
    pub rtt_min_ms: Option<i64>,
    pub rtt_max_ms: Option<i64>,
    pub rtt_sum_ms: Option<i64>,
}

impl LinkProbeBucket {
    pub fn rtt_avg_ms(&self) -> Option<i64> {
        match (self.ok_samples, self.rtt_sum_ms) {
            (ok, Some(sum)) if ok > 0 => Some(sum / ok),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkEventKind {
    Online,
    Offline,
    /// External IP changed: NAT mappings were flushed and a fresh round of port
    /// contention usually follows.
    WanRebind,
    /// The egress preserved the source port, so this host sits in the contention
    /// pool. This is a risk condition, not a clean bill of health.
    PortPreserved,
    /// The egress or a local TUN proxy rewrote the source port; this host never
    /// joins the contention.
    PortRewritten,
    /// Every STUN server failed, so the port judgement is temporarily unavailable.
    StunUnavailable,
}

impl LinkEventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Online => "online",
            Self::Offline => "offline",
            Self::WanRebind => "wan_rebind",
            Self::PortPreserved => "port_preserved",
            Self::PortRewritten => "port_rewritten",
            Self::StunUnavailable => "stun_unavailable",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "online" => Some(Self::Online),
            "offline" => Some(Self::Offline),
            "wan_rebind" => Some(Self::WanRebind),
            "port_preserved" => Some(Self::PortPreserved),
            "port_rewritten" => Some(Self::PortRewritten),
            "stun_unavailable" => Some(Self::StunUnavailable),
            _ => None,
        }
    }
}

/// Carried across probes so only transitions produce events.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct NatState {
    pub last_port_preserved: Option<bool>,
    pub last_available: Option<bool>,
}

/// Decides which events a probe result warrants. Pure on purpose: the caller
/// owns reading `previous_endpoint` and persisting the new one.
///
/// The first observation never produces an event — it only establishes the
/// baseline, otherwise every restart would file a spurious state change.
pub fn evaluate_nat(
    observation: Option<StunObservation>,
    previous_endpoint: Option<&str>,
    state: &mut NatState,
    node_id: &str,
    now: f64,
    servers: &str,
) -> Vec<LinkEvent> {
    let mut events = Vec::new();
    if node_id.is_empty() {
        return events;
    }
    let Some(observation) = observation else {
        // Report a sustained outage once rather than on every probe.
        if state.last_available != Some(false) {
            events.push(LinkEvent {
                occurred_at: now,
                node_id: node_id.to_string(),
                kind: LinkEventKind::StunUnavailable,
                detail: Some(servers.to_string()),
            });
        }
        state.last_available = Some(false);
        return events;
    };

    // Under a port-preserving NAT every probe uses a fresh local port, so the
    // external port always differs. Only an address change is a re-dial.
    let previous_address = previous_endpoint.and_then(|value| value.split(':').next());
    let current_address = observation.external_address.to_string();
    if let Some(previous_address) = previous_address {
        if previous_address != current_address {
            events.push(LinkEvent {
                occurred_at: now,
                node_id: node_id.to_string(),
                kind: LinkEventKind::WanRebind,
                detail: Some(format!("{previous_address} → {current_address}")),
            });
        }
    }

    let preserved = observation.port_preserved();
    if state
        .last_port_preserved
        .is_some_and(|last| last != preserved)
    {
        events.push(LinkEvent {
            occurred_at: now,
            node_id: node_id.to_string(),
            kind: if preserved {
                LinkEventKind::PortPreserved
            } else {
                LinkEventKind::PortRewritten
            },
            detail: Some(format!(
                "{} → {}",
                observation.local_port,
                observation.external_endpoint()
            )),
        });
    }
    state.last_port_preserved = Some(preserved);
    state.last_available = Some(true);
    events
}

#[derive(Debug, Clone, PartialEq)]
pub struct LinkEvent {
    pub occurred_at: f64,
    pub node_id: String,
    pub kind: LinkEventKind,
    /// Carries an overlay address; local UI only, never in `/v1/status`.
    pub detail: Option<String>,
}

pub fn bucket_start(time: f64) -> f64 {
    (time / BUCKET_WIDTH_S).floor() * BUCKET_WIDTH_S
}

/// Records one synchronization round trip; `rtt_ms` is `None` when no HTTP
/// response arrived. Each sample upserts directly into its bucket: row count
/// follows the bucket width rather than the sample count, so the write volume
/// is negligible and a crash cannot lose the open window.
pub fn record_sample(
    connection: &Connection,
    node_id: &str,
    at: f64,
    rtt_ms: Option<i64>,
) -> rusqlite::Result<()> {
    if node_id.is_empty() {
        return Ok(());
    }
    connection.execute(
        "INSERT INTO link_probe_bucket
           (node_id, bucket_at, samples, ok_samples, rtt_min_ms, rtt_max_ms, rtt_sum_ms)
         VALUES (?1, ?2, 1, ?3, ?4, ?4, ?4)
         ON CONFLICT(node_id, bucket_at) DO UPDATE SET
           samples = samples + 1,
           ok_samples = ok_samples + excluded.ok_samples,
           rtt_min_ms = MIN(COALESCE(rtt_min_ms, excluded.rtt_min_ms),
                            COALESCE(excluded.rtt_min_ms, rtt_min_ms)),
           rtt_max_ms = MAX(COALESCE(rtt_max_ms, excluded.rtt_max_ms),
                            COALESCE(excluded.rtt_max_ms, rtt_max_ms)),
           rtt_sum_ms = CASE WHEN excluded.rtt_sum_ms IS NULL THEN rtt_sum_ms
                             ELSE COALESCE(rtt_sum_ms, 0) + excluded.rtt_sum_ms END",
        rusqlite::params![
            node_id,
            bucket_start(at),
            i64::from(rtt_ms.is_some()),
            rtt_ms
        ],
    )?;
    Ok(())
}

pub fn buckets(
    connection: &Connection,
    since: f64,
    node_id: Option<&str>,
) -> rusqlite::Result<Vec<LinkProbeBucket>> {
    let mut sql = String::from(
        "SELECT node_id, bucket_at, samples, ok_samples, rtt_min_ms, rtt_max_ms, rtt_sum_ms
         FROM link_probe_bucket WHERE bucket_at >= ?1",
    );
    if node_id.is_some() {
        sql.push_str(" AND node_id = ?2");
    }
    sql.push_str(" ORDER BY bucket_at");
    let mut statement = connection.prepare(&sql)?;
    let map = |row: &rusqlite::Row<'_>| {
        Ok(LinkProbeBucket {
            node_id: row.get(0)?,
            bucket_at: row.get(1)?,
            samples: row.get(2)?,
            ok_samples: row.get(3)?,
            rtt_min_ms: row.get(4)?,
            rtt_max_ms: row.get(5)?,
            rtt_sum_ms: row.get(6)?,
        })
    };
    let rows = match node_id {
        Some(node) => statement.query_map(rusqlite::params![since, node], map)?,
        None => statement.query_map(rusqlite::params![since], map)?,
    };
    rows.collect()
}

pub fn record_event(connection: &Connection, event: &LinkEvent) -> rusqlite::Result<()> {
    if event.node_id.is_empty() {
        return Ok(());
    }
    connection.execute(
        "INSERT OR REPLACE INTO link_event (occurred_at, node_id, kind, detail)
         VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![
            event.occurred_at,
            event.node_id,
            event.kind.as_str(),
            event.detail
        ],
    )?;
    Ok(())
}

pub fn events(connection: &Connection, since: f64, limit: i64) -> rusqlite::Result<Vec<LinkEvent>> {
    let mut statement = connection.prepare(
        "SELECT occurred_at, node_id, kind, detail FROM link_event
         WHERE occurred_at >= ?1 ORDER BY occurred_at DESC LIMIT ?2",
    )?;
    let rows = statement.query_map(rusqlite::params![since, limit], |row| {
        Ok((
            row.get::<_, f64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    })?;
    let mut events = Vec::new();
    for row in rows {
        let (occurred_at, node_id, kind, detail) = row?;
        let Some(kind) = LinkEventKind::parse(&kind) else {
            continue;
        };
        events.push(LinkEvent {
            occurred_at,
            node_id,
            kind,
            detail,
        });
    }
    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::local::db::open_temp;

    /// Falls inside the [1_699_999_800, 1_700_000_100) bucket.
    const BASE: f64 = 1_700_000_000.0;

    #[test]
    fn samples_aggregate_into_aligned_buckets() {
        let (connection, _path) = open_temp("link-buckets");
        record_sample(&connection, "n1", BASE, Some(210)).unwrap();
        record_sample(&connection, "n1", BASE + 50.0, Some(190)).unwrap();
        record_sample(&connection, "n1", BASE + 400.0, Some(700)).unwrap();

        let rows = buckets(&connection, BASE - 600.0, None).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].bucket_at, 1_699_999_800.0);
        assert_eq!(rows[0].samples, 2);
        assert_eq!(rows[0].ok_samples, 2);
        assert_eq!(rows[0].rtt_min_ms, Some(190));
        assert_eq!(rows[0].rtt_max_ms, Some(210));
        assert_eq!(rows[0].rtt_avg_ms(), Some(200));
        assert_eq!(rows[1].bucket_at, 1_700_000_400.0);
        assert_eq!(rows[1].rtt_max_ms, Some(700));
    }

    /// A fully failed bucket must stay None, otherwise the chart draws a fake
    /// 0 ms line where there was no connectivity at all.
    #[test]
    fn fully_failed_bucket_keeps_no_latency() {
        let (connection, _path) = open_temp("link-failed");
        record_sample(&connection, "n1", BASE, None).unwrap();
        record_sample(&connection, "n1", BASE + 30.0, None).unwrap();

        let rows = buckets(&connection, BASE - 600.0, None).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].samples, 2);
        assert_eq!(rows[0].ok_samples, 0);
        assert_eq!(rows[0].rtt_min_ms, None);
        assert_eq!(rows[0].rtt_max_ms, None);
        assert_eq!(rows[0].rtt_avg_ms(), None);
    }

    /// Both orders matter: a reversed COALESCE only breaks one of them.
    #[test]
    fn failed_samples_do_not_move_latency_bounds() {
        let (connection, _path) = open_temp("link-mixed");
        record_sample(&connection, "fail-first", BASE, None).unwrap();
        record_sample(&connection, "fail-first", BASE + 15.0, Some(205)).unwrap();
        record_sample(&connection, "ok-first", BASE, Some(205)).unwrap();
        record_sample(&connection, "ok-first", BASE + 15.0, None).unwrap();

        for node in ["fail-first", "ok-first"] {
            let rows = buckets(&connection, BASE - 600.0, Some(node)).unwrap();
            assert_eq!(rows.len(), 1, "{node}");
            assert_eq!(rows[0].samples, 2, "{node}");
            assert_eq!(rows[0].ok_samples, 1, "{node}");
            assert_eq!(rows[0].rtt_min_ms, Some(205), "{node}");
            assert_eq!(rows[0].rtt_max_ms, Some(205), "{node}");
            assert_eq!(rows[0].rtt_avg_ms(), Some(205), "{node}");
        }
    }

    #[test]
    fn empty_node_id_is_ignored() {
        let (connection, _path) = open_temp("link-empty-node");
        record_sample(&connection, "", BASE, Some(100)).unwrap();
        assert!(buckets(&connection, BASE - 600.0, None).unwrap().is_empty());
    }

    #[test]
    fn events_read_back_newest_first() {
        let (connection, _path) = open_temp("link-events");
        record_event(
            &connection,
            &LinkEvent {
                occurred_at: BASE,
                node_id: "n1".into(),
                kind: LinkEventKind::Offline,
                detail: Some("http://host:8765".into()),
            },
        )
        .unwrap();
        record_event(
            &connection,
            &LinkEvent {
                occurred_at: BASE + 60.0,
                node_id: "n1".into(),
                kind: LinkEventKind::Online,
                detail: None,
            },
        )
        .unwrap();

        let rows = events(&connection, BASE - 600.0, 200).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].kind, LinkEventKind::Online);
        assert_eq!(rows[1].kind, LinkEventKind::Offline);
        assert_eq!(rows[1].detail.as_deref(), Some("http://host:8765"));
        assert_eq!(events(&connection, BASE - 600.0, 1).unwrap().len(), 1);
    }

    fn observation(local: u16, address: [u8; 4], external: u16) -> StunObservation {
        StunObservation {
            local_port: local,
            external_address: std::net::Ipv4Addr::from(address),
            external_port: external,
        }
    }

    #[test]
    fn first_observation_only_establishes_a_baseline() {
        let mut state = NatState::default();
        let events = evaluate_nat(
            Some(observation(4252, [223, 95, 78, 14], 4252)),
            None,
            &mut state,
            "local",
            1.0,
            "a",
        );
        assert!(events.is_empty());
        assert_eq!(state.last_port_preserved, Some(true));
    }

    /// A port-preserving NAT hands out a new local port each probe, so the
    /// external port always moves. Treating that as a re-dial would fire every
    /// single minute.
    #[test]
    fn changed_port_alone_is_not_a_rebind() {
        let mut state = NatState {
            last_port_preserved: Some(true),
            last_available: Some(true),
        };
        let events = evaluate_nat(
            Some(observation(61571, [223, 95, 78, 14], 61571)),
            Some("223.95.78.14:58682"),
            &mut state,
            "local",
            1.0,
            "a",
        );
        assert!(events.is_empty());
    }

    #[test]
    fn address_change_reports_a_rebind() {
        let mut state = NatState {
            last_port_preserved: Some(true),
            last_available: Some(true),
        };
        let events = evaluate_nat(
            Some(observation(4252, [124, 90, 54, 149], 4252)),
            Some("123.158.49.251:4252"),
            &mut state,
            "local",
            1.0,
            "a",
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, LinkEventKind::WanRebind);
        assert_eq!(
            events[0].detail.as_deref(),
            Some("123.158.49.251 → 124.90.54.149")
        );
    }

    #[test]
    fn port_preservation_transition_is_reported() {
        let mut state = NatState {
            last_port_preserved: Some(true),
            last_available: Some(true),
        };
        let events = evaluate_nat(
            Some(observation(65080, [223, 95, 78, 14], 65264)),
            Some("223.95.78.14:65080"),
            &mut state,
            "local",
            1.0,
            "a",
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, LinkEventKind::PortRewritten);
        assert_eq!(
            events[0].detail.as_deref(),
            Some("65080 → 223.95.78.14:65264")
        );
        assert_eq!(state.last_port_preserved, Some(false));
    }

    #[test]
    fn total_failure_degrades_once_then_recovers() {
        let mut state = NatState {
            last_port_preserved: Some(true),
            last_available: Some(true),
        };
        let first = evaluate_nat(None, None, &mut state, "local", 1.0, "a, b");
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].kind, LinkEventKind::StunUnavailable);
        assert_eq!(first[0].detail.as_deref(), Some("a, b"));

        let second = evaluate_nat(None, None, &mut state, "local", 2.0, "a, b");
        assert!(second.is_empty(), "sustained outage must not repeat");

        let recovered = evaluate_nat(
            Some(observation(4252, [223, 95, 78, 14], 4252)),
            Some("223.95.78.14:4252"),
            &mut state,
            "local",
            3.0,
            "a, b",
        );
        assert!(recovered.is_empty());
        assert_eq!(state.last_available, Some(true));
    }

    #[test]
    fn events_round_trip_every_kind() {
        let (connection, _path) = open_temp("link-kinds");
        let kinds = [
            LinkEventKind::Online,
            LinkEventKind::Offline,
            LinkEventKind::WanRebind,
            LinkEventKind::PortPreserved,
            LinkEventKind::PortRewritten,
            LinkEventKind::StunUnavailable,
        ];
        for (index, kind) in kinds.iter().enumerate() {
            record_event(
                &connection,
                &LinkEvent {
                    occurred_at: BASE + index as f64,
                    node_id: "n1".into(),
                    kind: *kind,
                    detail: None,
                },
            )
            .unwrap();
        }
        let rows = events(&connection, BASE - 1.0, 100).unwrap();
        assert_eq!(rows.len(), kinds.len());
    }

    /// Upgraded databases start empty; the read path must not fail.
    #[test]
    fn fresh_database_returns_empty_history() {
        let (connection, _path) = open_temp("link-fresh");
        assert!(buckets(&connection, 0.0, None).unwrap().is_empty());
        assert!(events(&connection, 0.0, 200).unwrap().is_empty());
    }
}
