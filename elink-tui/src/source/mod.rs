pub mod local;
pub mod remote;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::cluster::ClusterService;
use crate::config::Config;
use crate::model::Snapshot;
use local::history::History;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    Local,
    Remote,
}

impl SourceKind {
    pub fn label(self) -> &'static str {
        match self {
            SourceKind::Local => "local",
            SourceKind::Remote => "remote",
        }
    }
}

pub enum Command {
    /// Force an immediate re-collect, including a quota fetch in local mode.
    Refresh,
    SetKind(SourceKind),
    Quit,
}

pub struct Update {
    pub kind: SourceKind,
    pub result: Result<Snapshot, String>,
}

pub struct SourceHandle {
    pub commands: Sender<Command>,
    pub updates: Receiver<Update>,
    /// Shared with the UI so the stats page can read daily buckets directly.
    pub history: Arc<History>,
    /// True only while the bound listener has a current local snapshot.
    pub local_bridge_ready: Arc<AtomicBool>,
    pub cluster: Arc<ClusterService>,
}

/// Runs collection on a background thread so slow quota fetches never block
/// the UI loop. Snapshots stream back over the update channel.
pub fn spawn(config: Config, initial: SourceKind) -> Result<SourceHandle, String> {
    let (command_tx, command_rx) = mpsc::channel::<Command>();
    let (update_tx, update_rx) = mpsc::channel::<Update>();
    let history = Arc::new(History::new_with_legacy(
        config.usage_db.clone(),
        &config.history_cache,
    ));
    let cluster = Arc::new(
        ClusterService::load_with_legacy(
            config.usage_db.clone(),
            Some(&config.cluster_state),
            config.cluster_node_name.as_deref(),
        )
        .map_err(|error| error.to_string())?,
    );
    cluster.start_sync_worker(Duration::from_secs(15));
    let worker_history = Arc::clone(&history);
    let worker_cluster = Arc::clone(&cluster);
    let discovery_cluster = Arc::clone(&cluster);
    let local_bridge_ready = Arc::new(AtomicBool::new(false));
    let worker_bridge_ready = Arc::clone(&local_bridge_ready);
    thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(3))
            .build();
        let mut collector =
            local::LocalSource::with_cluster(&config, worker_history, worker_cluster);
        let mut kind = initial;
        let mut force = false;
        loop {
            let result = match kind {
                SourceKind::Remote => {
                    collector.disable_hook_listener();
                    discovery_cluster.pause_discovery();
                    worker_bridge_ready.store(false, Ordering::Release);
                    match &config.bridge_url {
                        Some(url) => remote::fetch(&agent, url),
                        None => Err("bridge_url is not configured".to_string()),
                    }
                }
                SourceKind::Local => {
                    // Quota fetches run on their own thread; this loop keeps
                    // its 2 s cadence and picks the results up when they land.
                    if collector.quota_due(force) {
                        collector.spawn_quota_refresh();
                    }
                    let result = collector.snapshot_now();
                    let ready = if result.is_ok() {
                        collector.ensure_hook_listener(&config.hook_listen)
                    } else {
                        collector.disable_hook_listener();
                        false
                    };
                    if ready {
                        if let Some(port) = lan_bridge_port(&config.hook_listen) {
                            discovery_cluster.start_discovery(port);
                        }
                    } else {
                        discovery_cluster.pause_discovery();
                    }
                    worker_bridge_ready.store(ready, Ordering::Release);
                    result
                }
            };
            force = false;
            if update_tx.send(Update { kind, result }).is_err() {
                break;
            }
            match command_rx.recv_timeout(Duration::from_secs_f64(config.status_poll_s)) {
                Ok(command) => {
                    let commands = std::iter::once(command).chain(command_rx.try_iter());
                    if apply_commands(commands, &mut kind, &mut force) {
                        break;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    });
    Ok(SourceHandle {
        commands: command_tx,
        updates: update_rx,
        history,
        local_bridge_ready,
        cluster,
    })
}

/// Coalesces commands already queued while collection was blocked. Repeated
/// refreshes become one forced cycle, and only the latest requested mode wins.
fn apply_commands(
    commands: impl IntoIterator<Item = Command>,
    kind: &mut SourceKind,
    force: &mut bool,
) -> bool {
    for command in commands {
        match command {
            Command::Quit => return true,
            Command::Refresh => *force = true,
            Command::SetKind(value) => {
                *kind = value;
                *force = true;
            }
        }
    }
    false
}

/// The bridge port to advertise over mDNS, only when the hook listener binds a
/// routable (non-loopback) address peers can actually reach. Advertising a
/// loopback-only bridge would point peers at a port they cannot connect to.
fn lan_bridge_port(listen: &str) -> Option<u16> {
    let (host, port) = listen.rsplit_once(':')?;
    let host = host.trim_matches(['[', ']']);
    let port: u16 = port.parse().ok()?;
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address.is_loopback());
    (!loopback).then_some(port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesces_repeated_refreshes_and_keeps_latest_mode() {
        let mut kind = SourceKind::Local;
        let mut force = false;

        let quit = apply_commands(
            [
                Command::Refresh,
                Command::Refresh,
                Command::SetKind(SourceKind::Remote),
                Command::SetKind(SourceKind::Local),
            ],
            &mut kind,
            &mut force,
        );

        assert!(!quit);
        assert!(force);
        assert_eq!(kind, SourceKind::Local);
    }

    #[test]
    fn lan_bridge_port_only_advertises_routable_listeners() {
        assert_eq!(lan_bridge_port("0.0.0.0:8765"), Some(8765));
        assert_eq!(lan_bridge_port("192.168.1.10:9000"), Some(9000));
        assert_eq!(lan_bridge_port("[::]:8765"), Some(8765));
        assert_eq!(lan_bridge_port("127.0.0.1:8765"), None);
        assert_eq!(lan_bridge_port("localhost:8765"), None);
        assert_eq!(lan_bridge_port("[::1]:8765"), None);
        assert_eq!(lan_bridge_port(""), None);
        assert_eq!(lan_bridge_port("0.0.0.0:not-a-port"), None);
    }
}
