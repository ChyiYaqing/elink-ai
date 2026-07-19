pub mod local;
pub mod remote;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

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
}

/// Runs collection on a background thread so slow quota fetches never block
/// the UI loop. Snapshots stream back over the update channel.
pub fn spawn(config: Config, initial: SourceKind) -> SourceHandle {
    let (command_tx, command_rx) = mpsc::channel::<Command>();
    let (update_tx, update_rx) = mpsc::channel::<Update>();
    let history = Arc::new(History::new(config.history_cache.clone()));
    let worker_history = Arc::clone(&history);
    let local_bridge_ready = Arc::new(AtomicBool::new(false));
    let worker_bridge_ready = Arc::clone(&local_bridge_ready);
    thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(3))
            .build();
        let mut collector = local::LocalSource::new(&config, worker_history);
        let mut kind = initial;
        let mut force = false;
        loop {
            let result = match kind {
                SourceKind::Remote => {
                    collector.disable_hook_listener();
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
    SourceHandle {
        commands: command_tx,
        updates: update_rx,
        history,
        local_bridge_ready,
    }
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
}
