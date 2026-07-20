use std::fs;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde::Deserialize;

use crate::cluster::ClusterCommand;
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
        })
    }
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

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
                command: None,
            };

            let result = Config::load(&cli);
            let _ = fs::remove_file(path);

            assert!(result.is_err());
        }
    }
}
