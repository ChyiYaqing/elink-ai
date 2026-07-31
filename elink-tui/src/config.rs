use std::fs;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde::Deserialize;

use std::time::Duration;

use crate::cluster::ClusterCommand;
use crate::lighthouse::{LighthouseConfig, LogSource};
use crate::source::SourceKind;
use crate::util::expand_tilde;

#[derive(Parser, Debug)]
#[command(
    name = "elink-tui",
    version,
    about = "Keyboard-driven terminal dashboard for Claude Code and Codex usage"
)]
pub struct Cli {
    /// Bridge URL such as http://mac:8765 (enables remote mode)
    #[arg(long)]
    pub bridge: Option<String>,
    /// Config file path (default ~/.config/elink-ai/tui.toml)
    #[arg(long)]
    pub config: Option<PathBuf>,
    /// Collect one snapshot, print it as JSON, and exit
    #[arg(long)]
    pub once: bool,
    /// Collect one snapshot, print a one-line summary (for tmux/waybar), exit
    #[arg(long, conflicts_with = "once")]
    pub compact: bool,
    /// Run as a lighthouse collector: no TUI, no usage, no cluster pairing.
    /// Reads the local nebula log and serves the source-port aggregate.
    #[arg(long, conflicts_with_all = ["once", "compact"])]
    pub headless: bool,
    #[command(subcommand)]
    pub command: Option<AppCommand>,
}

#[derive(Debug, Subcommand)]
pub enum AppCommand {
    /// Manage encrypted multi-node usage synchronization
    Cluster {
        #[command(subcommand)]
        command: ClusterCommand,
    },
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileConfig {
    mode: Option<String>,
    bridge_url: Option<String>,
    refresh: FileRefresh,
    paths: FilePaths,
    hooks: FileHooks,
    device: FileDevice,
    cluster: FileCluster,
    lighthouse: FileLighthouse,
    mesh: FileMesh,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileMesh {
    /// Where a lighthouse collector publishes the roster, e.g.
    /// `http://192.168.100.200:8767`. Absent disables the mesh view: without a
    /// roster there is no list of devices to probe.
    lighthouse_url: Option<String>,
    interval_s: Option<u64>,
    /// How far back the rendered min/avg/max reaches.
    window_s: Option<i64>,
}

/// Client-side view of the nebula overlay. Separate from `[lighthouse]`, which
/// configures the collector: a node is normally one or the other, not both.
#[derive(Debug, Clone)]
pub struct MeshConfig {
    pub lighthouse_url: String,
    pub interval: Duration,
    pub window_s: i64,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileLighthouse {
    /// systemd unit to read with `journalctl -u <unit>`
    journal_unit: Option<String>,
    /// Plain log file; takes precedence over `journal_unit` when both are set
    log_file: Option<String>,
    default_port: Option<u16>,
    listen: Option<String>,
    interval_s: Option<u64>,
    /// This lighthouse's own certName and overlay address; it never appears in
    /// its own log, so the roster misses it unless it is named here.
    self_name: Option<String>,
    self_overlay: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileCluster {
    node_name: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileDevice {
    url: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileHooks {
    listen: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FileRefresh {
    status_poll_s: Option<f64>,
    quota_fetch_s: Option<u64>,
}

#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct FilePaths {
    claude_home: Option<String>,
    codex_home: Option<String>,
    statusline_cache: Option<String>,
    usage_db: Option<String>,
    // Legacy JSON paths are still accepted as one-time import sources.
    quota_cache: Option<String>,
    history_cache: Option<String>,
    cluster_state: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub mode: SourceKind,
    pub bridge_url: Option<String>,
    pub status_poll_s: f64,
    pub quota_fetch_s: u64,
    pub claude_home: PathBuf,
    pub codex_home: PathBuf,
    pub statusline_cache: PathBuf,
    pub usage_db: PathBuf,
    /// Previous JSON stores. They are read only when the corresponding
    /// SQLite tables are empty, so upgrades retain existing state.
    pub quota_cache: PathBuf,
    pub history_cache: PathBuf,
    pub cluster_state: PathBuf,
    pub cluster_node_name: Option<String>,
    /// Address for the local `POST /v1/event` hook listener (the mac-app
    /// bridge port, so the repo's hook scripts work unchanged). Empty
    /// disables it.
    pub hook_listen: String,
    /// Pi agent base URL such as `http://pi:8766`; enables the device page.
    pub device_url: Option<String>,
    /// Present only when the config file has a usable `[lighthouse]` section.
    pub lighthouse: Option<LighthouseConfig>,
    /// Present only when `[mesh] lighthouse_url` names a collector to poll.
    pub mesh: Option<MeshConfig>,
}

impl Config {
    pub fn load(cli: &Cli) -> Result<Self> {
        let path = cli
            .config
            .clone()
            .unwrap_or_else(|| expand_tilde("~/.config/elink-ai/tui.toml"));
        let file = if path.is_file() {
            let text = fs::read_to_string(&path)
                .with_context(|| format!("cannot read config file {}", path.display()))?;
            toml::from_str::<FileConfig>(&text)
                .with_context(|| format!("invalid config file {}", path.display()))?
        } else if cli.config.is_some() {
            bail!("config file not found: {}", path.display());
        } else {
            FileConfig::default()
        };

        let bridge_url = cli
            .bridge
            .clone()
            .or(file.bridge_url)
            .map(|value| value.trim_end_matches('/').to_string());
        let mode = if cli.bridge.is_some() {
            SourceKind::Remote
        } else {
            match file.mode.as_deref() {
                None | Some("local") => SourceKind::Local,
                Some("remote") => SourceKind::Remote,
                Some(other) => bail!("invalid mode {other:?}; expected \"local\" or \"remote\""),
            }
        };
        if mode == SourceKind::Remote && bridge_url.is_none() {
            bail!("remote mode requires bridge_url (config) or --bridge");
        }
        let status_poll_s = file.refresh.status_poll_s.unwrap_or(2.0).max(0.5);
        if !status_poll_s.is_finite()
            || std::time::Duration::try_from_secs_f64(status_poll_s).is_err()
        {
            bail!("refresh.status_poll_s must be a finite, representable duration");
        }

        Ok(Self {
            mode,
            bridge_url,
            status_poll_s,
            quota_fetch_s: file.refresh.quota_fetch_s.unwrap_or(120).max(60),
            claude_home: file
                .paths
                .claude_home
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.claude")),
            codex_home: file
                .paths
                .codex_home
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.codex")),
            statusline_cache: file
                .paths
                .statusline_cache
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.cache/statusline/last.json")),
            usage_db: file
                .paths
                .usage_db
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.local/state/elink-ai/usage.db")),
            quota_cache: file
                .paths
                .quota_cache
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.local/state/elink-ai/quota.json")),
            history_cache: file
                .paths
                .history_cache
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.local/state/elink-ai/history.json")),
            cluster_state: file
                .paths
                .cluster_state
                .as_deref()
                .map(expand_tilde)
                .unwrap_or_else(|| expand_tilde("~/.local/state/elink-ai/cluster.json")),
            cluster_node_name: file
                .cluster
                .node_name
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            hook_listen: file
                .hooks
                .listen
                .unwrap_or_else(|| "127.0.0.1:8765".to_string()),
            device_url: file
                .device
                .url
                .map(|value| value.trim_end_matches('/').to_string())
                .filter(|value| !value.is_empty()),
            lighthouse: {
                let lighthouse = file.lighthouse;
                // A file path wins over a journal unit: it is the more specific
                // instruction and needs no elevated journal access.
                let source = lighthouse
                    .log_file
                    .as_deref()
                    .filter(|value| !value.is_empty())
                    .map(|value| LogSource::File {
                        path: expand_tilde(value),
                    })
                    .or_else(|| {
                        lighthouse
                            .journal_unit
                            .as_deref()
                            .filter(|value| !value.is_empty())
                            .map(|unit| LogSource::Journal {
                                unit: unit.to_string(),
                            })
                    });
                let self_overlay = lighthouse.self_overlay.filter(|value| !value.is_empty());
                source.map(|source| LighthouseConfig {
                    source,
                    default_port: lighthouse.default_port.unwrap_or(4242),
                    listen: lighthouse
                        .listen
                        .filter(|value| !value.is_empty())
                        .unwrap_or_else(|| default_listen(self_overlay.as_deref())),
                    interval: Duration::from_secs(lighthouse.interval_s.unwrap_or(60).max(5)),
                    self_name: lighthouse.self_name.filter(|value| !value.is_empty()),
                    self_overlay,
                })
            },
            mesh: file
                .mesh
                .lighthouse_url
                .filter(|value| !value.is_empty())
                .map(|lighthouse_url| MeshConfig {
                    lighthouse_url,
                    // Thirty seconds keeps a node's recovery visible quickly
                    // without making the mesh a meaningful source of traffic.
                    interval: Duration::from_secs(file.mesh.interval_s.unwrap_or(30).max(5)),
                    window_s: file.mesh.window_s.unwrap_or(3_600).max(300),
                }),
        })
    }
}

/// Where the lighthouse listens when the config does not say.
///
/// The roster names every node, its overlay address, and its WAN mapping, and it
/// is served as plaintext HTTP with no authentication. The only thing keeping
/// that document private is the address it is bound to, so the default must not
/// be `0.0.0.0` — a lighthouse runs on a public VPS as often as not, and a
/// default that publishes the network topology to the internet is a default that
/// is wrong in exactly the deployment it is most likely to meet.
///
/// `self_overlay` is the overlay address of this very host, so binding to it
/// serves every node on the VPN and nobody else. Without it there is nothing
/// safe to guess: loopback keeps the document private and makes the missing
/// configuration obvious the first time another node asks for it.
fn default_listen(self_overlay: Option<&str>) -> String {
    match self_overlay {
        Some(overlay) => format!("{overlay}:8767"),
        None => "127.0.0.1:8767".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    /// The roster is unauthenticated plaintext listing every node and its WAN
    /// address; a wildcard default publishes it to whatever the host is exposed
    /// to, which for a VPS is the internet.
    #[test]
    fn lighthouse_never_defaults_to_a_wildcard_address() {
        assert_eq!(
            default_listen(Some("192.168.100.200")),
            "192.168.100.200:8767"
        );
        assert_eq!(default_listen(None), "127.0.0.1:8767");
        for listen in [default_listen(Some("192.168.100.200")), default_listen(None)] {
            assert!(
                !listen.starts_with("0.0.0.0") && !listen.starts_with("[::]"),
                "default must not be a wildcard: {listen}"
            );
        }
    }

    #[test]
    fn rejects_invalid_status_poll_intervals() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        for (index, value) in ["inf", "1e300"].into_iter().enumerate() {
            let path = std::env::temp_dir().join(format!("elink-tui-config-{suffix}-{index}.toml"));
            fs::write(&path, format!("[refresh]\nstatus_poll_s = {value}\n"))
                .expect("write config");
            let cli = Cli {
                bridge: None,
                config: Some(path.clone()),
                once: false,
                compact: false,
                headless: false,
                command: None,
            };

            let result = Config::load(&cli);
            let _ = fs::remove_file(path);

            assert!(result.is_err());
        }
    }
}
