use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::cluster::ClusterService;
use crate::device::{self, DeviceCommand, DeviceLink};
use crate::model::Snapshot;
use crate::source::local::history::{History, StatsRange};
use crate::source::{Command, SourceKind, Update};
use crate::update::{SharedUpdate, UpdateInfo, UpdateSlot};

const HINT_VISIBLE_SECONDS: u64 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BridgeBlocker {
    RemoteMode,
    Loopback,
    ListenerUnavailable,
    NoFreshSnapshot,
}

impl BridgeBlocker {
    fn hint(self) -> &'static str {
        match self {
            Self::RemoteMode => "switch to local mode before bridging this device",
            Self::Loopback => "hooks.listen is loopback-only; set listen = \"0.0.0.0:8765\" first",
            Self::ListenerUnavailable => "local bridge listener is unavailable",
            Self::NoFreshSnapshot => "waiting for a fresh local snapshot",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    Dashboard,
    Stats,
    Device,
    Cluster,
}

pub struct LocalData {
    pub history: Arc<History>,
    pub cluster: Arc<ClusterService>,
}

pub struct App {
    pub snapshot: Option<Snapshot>,
    pub received_at: Option<Instant>,
    pub error: Option<String>,
    pub kind: SourceKind,
    pub bridge_configured: bool,
    pub focus: usize,
    pub scroll: [usize; 2],
    pub show_help: bool,
    pub should_quit: bool,
    pub view: View,
    pub stats_range: StatsRange,
    pub stats_node_id: Option<String>,
    pub history: Arc<History>,
    pub device: Option<DeviceLink>,
    pub update_available: Option<UpdateInfo>,
    pub cluster: Arc<ClusterService>,
    device_url: Option<String>,
    hook_listen: String,
    local_bridge_ready: Arc<AtomicBool>,
    local_snapshot_max_age: Duration,
    snapshot_kind: Option<SourceKind>,
    update_slot: SharedUpdate,
    hint: Option<(String, Instant)>,
}

impl App {
    pub fn new(
        kind: SourceKind,
        bridge_configured: bool,
        local: LocalData,
        device_url: Option<String>,
        hook_listen: String,
        local_bridge_ready: Arc<AtomicBool>,
        status_poll_s: f64,
    ) -> Self {
        Self {
            snapshot: None,
            received_at: None,
            error: None,
            kind,
            bridge_configured,
            focus: 0,
            scroll: [0, 0],
            show_help: false,
            should_quit: false,
            view: View::Dashboard,
            stats_range: StatsRange::Week,
            stats_node_id: None,
            history: local.history,
            device: device_url.clone().map(DeviceLink::spawn),
            update_available: None,
            cluster: local.cluster,
            device_url,
            hook_listen,
            local_bridge_ready,
            local_snapshot_max_age: Duration::from_secs_f64((status_poll_s * 2.0).max(5.0)),
            snapshot_kind: None,
            update_slot: SharedUpdate::default(),
            hint: None,
        }
    }

    pub fn apply(&mut self, update: Update) {
        self.kind = update.kind;
        if self.kind == SourceKind::Remote && matches!(self.view, View::Stats | View::Cluster) {
            self.set_view(View::Dashboard);
        }
        match update.result {
            Ok(snapshot) => {
                self.snapshot = Some(snapshot);
                self.received_at = Some(Instant::now());
                self.snapshot_kind = Some(update.kind);
                self.error = None;
                if self.stats_node_id.as_ref().is_some_and(|selected| {
                    !self
                        .cluster
                        .stats_nodes()
                        .iter()
                        .any(|node| &node.node_id == selected)
                }) {
                    self.stats_node_id = None;
                }
                self.clamp_scroll();
            }
            Err(error) => self.error = Some(error),
        }
    }

    /// Consumes a finished update check into a hint and the header marker.
    pub fn poll_update_check(&mut self) {
        let mut slot = self
            .update_slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let UpdateSlot::Done(result) = std::mem::take(&mut *slot) else {
            return;
        };
        drop(slot);
        match result {
            Ok(info) => {
                let hint = if info.newer {
                    format!("update available: {} — {}", info.tag, info.url)
                } else {
                    format!("up to date (latest release {})", info.tag)
                };
                self.set_hint(&hint);
                self.update_available = Some(info).filter(|info| info.newer);
            }
            Err(error) => self.set_hint(&error),
        }
    }

    pub fn hint(&self) -> Option<&str> {
        match &self.hint {
            Some((text, at)) if at.elapsed().as_secs() < HINT_VISIBLE_SECONDS => Some(text),
            _ => None,
        }
    }

    pub fn on_key(&mut self, key: KeyEvent, commands: &Sender<Command>) {
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.should_quit = true;
            return;
        }
        if self.show_help {
            match key.code {
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Esc | KeyCode::Char('?') => self.show_help = false,
                _ => {}
            }
            return;
        }
        if self.view == View::Device {
            self.on_device_key(key);
            return;
        }
        if self.view == View::Cluster {
            self.on_cluster_key(key);
            return;
        }
        match key.code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Char('s') => {
                if self.kind == SourceKind::Remote {
                    self.set_hint("stats are unavailable in remote mode");
                } else {
                    self.set_view(match self.view {
                        View::Stats => View::Dashboard,
                        _ => View::Stats,
                    });
                }
            }
            KeyCode::Char('d') => self.open_device(),
            KeyCode::Char('c') => {
                if self.kind == SourceKind::Local {
                    self.set_view(View::Cluster);
                } else {
                    self.set_hint("cluster management is available in local mode");
                }
            }
            KeyCode::Char('u') => {
                crate::update::spawn_check(Arc::clone(&self.update_slot));
                self.set_hint("checking for updates…");
            }
            KeyCode::Esc if self.view == View::Stats => self.set_view(View::Dashboard),
            KeyCode::Char('w') if self.view == View::Stats => self.stats_range = StatsRange::Week,
            KeyCode::Char('m') if self.view == View::Stats => self.stats_range = StatsRange::Month,
            KeyCode::Char('y') if self.view == View::Stats => self.stats_range = StatsRange::Year,
            KeyCode::Char('n') if self.view == View::Stats => self.cycle_stats_node(),
            KeyCode::Char('r') => {
                let _ = commands.send(Command::Refresh);
                self.set_hint("refreshing…");
            }
            KeyCode::Tab
            | KeyCode::BackTab
            | KeyCode::Left
            | KeyCode::Right
            | KeyCode::Char('h')
            | KeyCode::Char('l') => self.focus ^= 1,
            KeyCode::Char('1') => self.focus = 0,
            KeyCode::Char('2') => self.focus = 1,
            KeyCode::Up | KeyCode::Char('k') => {
                self.scroll[self.focus] = self.scroll[self.focus].saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.scroll[self.focus] += 1;
                self.clamp_scroll();
            }
            KeyCode::Char('m') => {
                if self.bridge_configured || self.kind == SourceKind::Remote {
                    let next = match self.kind {
                        SourceKind::Local => SourceKind::Remote,
                        SourceKind::Remote => SourceKind::Local,
                    };
                    let _ = commands.send(Command::SetKind(next));
                    self.set_hint(match next {
                        SourceKind::Local => "switching to local mode…",
                        SourceKind::Remote => "switching to remote mode…",
                    });
                } else {
                    self.set_hint("configure bridge_url to enable remote mode");
                }
            }
            _ => {}
        }
    }

    fn on_device_key(&mut self, key: KeyEvent) {
        let Some(device) = &self.device else {
            self.set_view(View::Dashboard);
            return;
        };
        match key.code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Esc | KeyCode::Char('d') => self.set_view(View::Dashboard),
            KeyCode::Char('1') => device.send(DeviceCommand::SetMode("dashboard")),
            KeyCode::Char('2') => device.send(DeviceCommand::SetMode("claude")),
            KeyCode::Char('3') => device.send(DeviceCommand::SetMode("codex")),
            KeyCode::Char('p') => device.send(DeviceCommand::Refresh("smart")),
            KeyCode::Char('f') => device.send(DeviceCommand::Refresh("full")),
            KeyCode::Char('b') => {
                if let Some(blocker) = self.bridge_blocker() {
                    self.set_hint(blocker.hint());
                    return;
                }
                let url = self
                    .device_url
                    .as_deref()
                    .and_then(|device_url| device::local_bridge_url(device_url, &self.hook_listen));
                match url {
                    Some(url) => {
                        device.send(DeviceCommand::SetBridge(url.clone()));
                        self.set_hint(&format!("pointing device at {url}"));
                    }
                    None => self.set_hint("enable the [hooks] listener to serve as a bridge"),
                }
            }
            _ => {}
        }
    }

    fn on_cluster_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Esc | KeyCode::Char('c') => self.set_view(View::Dashboard),
            KeyCode::Char('p') => match self.cluster.start_pairing() {
                Ok(code) => self.set_hint(&format!("pairing code: {code}")),
                Err(error) => self.set_hint(&error.to_string()),
            },
            KeyCode::Char('r') => {
                self.cluster.request_sync();
                self.set_hint("cluster sync requested");
            }
            _ => {}
        }
    }

    fn open_device(&mut self) {
        if self.device.is_some() {
            self.set_view(View::Device);
        } else {
            self.set_hint("configure [device] url (e.g. http://pi:8766) to control a display");
        }
    }

    fn set_view(&mut self, view: View) {
        self.view = view;
        if let Some(device) = &self.device {
            device.set_active(view == View::Device);
        }
    }

    fn set_hint(&mut self, text: &str) {
        self.hint = Some((text.to_string(), Instant::now()));
    }

    fn cycle_stats_node(&mut self) {
        let nodes = self.cluster.stats_nodes();
        if nodes.len() <= 1 {
            self.stats_node_id = None;
            self.set_hint("no additional cluster nodes");
            return;
        }
        let next = match self
            .stats_node_id
            .as_ref()
            .and_then(|selected| nodes.iter().position(|node| &node.node_id == selected))
        {
            None => Some(nodes[0].node_id.clone()),
            Some(index) if index + 1 < nodes.len() => Some(nodes[index + 1].node_id.clone()),
            Some(_) => None,
        };
        let label = next
            .as_ref()
            .and_then(|node_id| nodes.iter().find(|node| &node.node_id == node_id))
            .map(|node| node.name.as_str())
            .unwrap_or("all nodes");
        self.stats_node_id = next;
        self.set_hint(&format!("stats source: {label}"));
    }

    fn bridge_blocker(&self) -> Option<BridgeBlocker> {
        if self.kind != SourceKind::Local {
            return Some(BridgeBlocker::RemoteMode);
        }
        if listener_is_loopback(&self.hook_listen) {
            return Some(BridgeBlocker::Loopback);
        }
        if !self.local_bridge_ready.load(Ordering::Acquire) {
            return Some(BridgeBlocker::ListenerUnavailable);
        }
        let fresh = self.snapshot_kind == Some(SourceKind::Local)
            && self
                .received_at
                .is_some_and(|at| at.elapsed() <= self.local_snapshot_max_age);
        if !fresh {
            return Some(BridgeBlocker::NoFreshSnapshot);
        }
        None
    }

    fn clamp_scroll(&mut self) {
        let Some(snapshot) = &self.snapshot else {
            return;
        };
        let counts = [
            snapshot.claude.model_usage_today.len(),
            snapshot.codex.model_usage_today.len(),
        ];
        for (scroll, count) in self.scroll.iter_mut().zip(counts) {
            *scroll = (*scroll).min(count.saturating_sub(1));
        }
    }
}

fn listener_is_loopback(address: &str) -> bool {
    let Some((host, _)) = address.rsplit_once(':') else {
        return false;
    };
    let host = host.trim_matches(['[', ']']);
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicBool;
    use std::sync::mpsc;

    use super::*;
    use crate::model::ProviderStatus;

    fn temp_db(label: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-app-test-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        std::env::temp_dir().join(unique).join("usage.db")
    }

    fn test_app(kind: SourceKind, listen: &str, listener_bound: bool) -> App {
        let history = Arc::new(History::new(temp_db("history")));
        App::new(
            kind,
            true,
            LocalData {
                history,
                cluster: Arc::new(
                    ClusterService::load(temp_db("cluster"), Some("test-node"))
                        .expect("load cluster state"),
                ),
            },
            None,
            listen.to_string(),
            Arc::new(AtomicBool::new(listener_bound)),
            2.0,
        )
    }

    fn snapshot() -> Snapshot {
        Snapshot {
            schema_version: 1,
            generated_at: Some(crate::util::epoch_now()),
            usage_fetched_at: None,
            cluster: None,
            claude: ProviderStatus::default(),
            codex: ProviderStatus::default(),
        }
    }

    #[test]
    fn bridge_to_here_rejects_every_unsafe_local_state() {
        let mut loopback = test_app(SourceKind::Local, "127.0.0.1:8765", true);
        loopback.apply(Update {
            kind: SourceKind::Local,
            result: Ok(snapshot()),
        });
        assert_eq!(loopback.bridge_blocker(), Some(BridgeBlocker::Loopback));

        let mut bind_failed = test_app(SourceKind::Local, "0.0.0.0:8765", false);
        bind_failed.apply(Update {
            kind: SourceKind::Local,
            result: Ok(snapshot()),
        });
        assert_eq!(
            bind_failed.bridge_blocker(),
            Some(BridgeBlocker::ListenerUnavailable)
        );

        let remote = test_app(SourceKind::Remote, "0.0.0.0:8765", true);
        assert_eq!(remote.bridge_blocker(), Some(BridgeBlocker::RemoteMode));

        let mut stale = test_app(SourceKind::Local, "0.0.0.0:8765", true);
        stale.apply(Update {
            kind: SourceKind::Local,
            result: Ok(snapshot()),
        });
        stale.received_at =
            Some(Instant::now() - stale.local_snapshot_max_age - Duration::from_secs(1));
        assert_eq!(stale.bridge_blocker(), Some(BridgeBlocker::NoFreshSnapshot));
    }

    #[test]
    fn remote_mode_disables_local_stats() {
        let mut app = test_app(SourceKind::Remote, "", false);
        let (commands, _) = mpsc::channel();

        app.on_key(
            KeyEvent::new(KeyCode::Char('s'), KeyModifiers::NONE),
            &commands,
        );

        assert_eq!(app.view, View::Dashboard);
        assert_eq!(app.hint(), Some("stats are unavailable in remote mode"));
    }

    #[test]
    fn switching_to_remote_closes_an_open_stats_view() {
        let mut app = test_app(SourceKind::Local, "", false);
        app.view = View::Stats;

        app.apply(Update {
            kind: SourceKind::Remote,
            result: Ok(snapshot()),
        });

        assert_eq!(app.view, View::Dashboard);
    }
}
