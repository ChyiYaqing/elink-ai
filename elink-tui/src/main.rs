use std::time::Duration;

use anyhow::{anyhow, Result};
use clap::Parser;
use ratatui::crossterm::event::{self, Event, KeyEventKind};

use elink_tui::app::{App, LocalData};
use elink_tui::config::{AppCommand, Cli, Config};
use elink_tui::source::{self, Command, SourceKind};
use elink_tui::ui;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalCollectionMode {
    Cached,
    Fresh,
}

fn local_collection_mode(compact: bool) -> LocalCollectionMode {
    if compact {
        LocalCollectionMode::Cached
    } else {
        LocalCollectionMode::Fresh
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = Config::load(&cli)?;
    if let Some(AppCommand::Cluster { command }) = &cli.command {
        let cluster = elink_tui::cluster::ClusterService::load_with_legacy(
            config.usage_db.clone(),
            Some(&config.cluster_state),
            config.cluster_node_name.as_deref(),
        )?;
        println!("{}", cluster.run_command(command)?);
        return Ok(());
    }
    if cli.headless {
        let lighthouse = config.lighthouse.clone().ok_or_else(|| {
            anyhow!("--headless requires a [lighthouse] section with journal_unit or log_file")
        })?;
        return elink_tui::lighthouse::run_headless(&config.usage_db, lighthouse);
    }
    if cli.once || cli.compact {
        return run_once(&config, cli.compact);
    }
    run_tui(config)
}

fn run_once(config: &Config, compact: bool) -> Result<()> {
    let snapshot = match config.mode {
        SourceKind::Remote => {
            let agent = ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(3))
                .build();
            let url = config
                .bridge_url
                .as_deref()
                .ok_or_else(|| anyhow!("remote mode requires bridge_url"))?;
            source::remote::fetch(&agent, url).map_err(|error| anyhow!(error))?
        }
        SourceKind::Local => match local_collection_mode(compact) {
            LocalCollectionMode::Cached => source::local::LocalSource::for_compact(config)
                .map_err(|error| anyhow!(error))?
                .snapshot_for_compact(),
            LocalCollectionMode::Fresh => {
                let history =
                    std::sync::Arc::new(source::local::history::History::new_with_legacy(
                        config.usage_db.clone(),
                        &config.history_cache,
                    ));
                source::local::LocalSource::new(config, history)
                    .map_err(|error| anyhow!(error))?
                    .collect(true)
            }
        }
        .map_err(|error| anyhow!(error))?,
    };
    if compact {
        println!("{}", ui::compact_line(&snapshot));
    } else {
        println!("{}", serde_json::to_string_pretty(&snapshot)?);
    }
    Ok(())
}

fn run_tui(config: Config) -> Result<()> {
    let bridge_configured = config.bridge_url.is_some();
    let initial = config.mode;
    let device_url = config.device_url.clone();
    let hook_listen = config.hook_listen.clone();
    let status_poll_s = config.status_poll_s;
    let handle = source::spawn(config, initial).map_err(|error| anyhow!(error))?;
    let mut app = App::new(
        initial,
        bridge_configured,
        LocalData {
            history: handle.history.clone(),
            cluster: handle.cluster.clone(),
        },
        device_url,
        hook_listen,
        handle.local_bridge_ready.clone(),
        status_poll_s,
    );

    let mut terminal = ratatui::init();
    let mut title = String::new();
    let result = (|| -> Result<()> {
        while !app.should_quit {
            while let Ok(update) = handle.updates.try_recv() {
                app.apply(update);
            }
            app.poll_update_check();
            let next_title = ui::terminal_title(app.snapshot.as_ref());
            if next_title != title {
                let _ = ratatui::crossterm::execute!(
                    std::io::stdout(),
                    ratatui::crossterm::terminal::SetTitle(&next_title)
                );
                title = next_title;
            }
            terminal.draw(|frame| ui::draw(frame, &app))?;
            if event::poll(Duration::from_millis(100))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind == KeyEventKind::Press {
                        app.on_key(key, &handle.commands);
                    }
                }
            }
        }
        Ok(())
    })();
    ratatui::restore();
    let _ = handle.commands.send(Command::Quit);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_uses_cached_quota_but_once_refreshes_it() {
        assert_eq!(local_collection_mode(true), LocalCollectionMode::Cached);
        assert_eq!(local_collection_mode(false), LocalCollectionMode::Fresh);
    }
}
