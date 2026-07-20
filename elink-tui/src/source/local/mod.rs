pub mod creds;
pub mod db;
pub mod history;
pub mod hooks;
pub mod quota;
pub mod sessions;
pub mod store;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::cluster::ClusterService;
use crate::config::Config;
use crate::model::{ProviderStatus, Snapshot};
use crate::util::epoch_now;
use history::History;
use hooks::HookRegistry;
use quota::{ProviderUsage, QuotaFetcher, UsageWindow};
use sessions::{ProviderScan, SessionScanner};

const BACKFILL_DAYS: i64 = 366;
const LISTENER_RETRY_DELAY: Duration = Duration::from_secs(5);

pub struct LocalSource {
    scanner: SessionScanner,
    quota: Arc<QuotaFetcher>,
    hooks: Arc<HookRegistry>,
    history: Option<Arc<History>>,
    served_status: hooks::SharedStatus,
    listener: Option<hooks::ListenerHandle>,
    listener_retry_at: Option<Instant>,
    claude_home: PathBuf,
    codex_home: PathBuf,
    backfill_started: bool,
    /// The bucket timezone the running backfill was scanned under; a change
    /// (e.g. joining a cluster in another zone) re-runs it to rebucket days.
    backfill_tz: Option<String>,
    backfill_generation: Arc<AtomicU64>,
    backfill_running: Arc<AtomicBool>,
    cluster: Arc<ClusterService>,
}

impl LocalSource {
    pub fn new(config: &Config, history: Arc<History>) -> Result<Self, String> {
        let cluster = Arc::new(
            ClusterService::load_with_legacy(
                config.usage_db.clone(),
                Some(&config.cluster_state),
                config.cluster_node_name.as_deref(),
            )
            .map_err(|error| error.to_string())?,
        );
        Ok(Self::build(config, Some(history), cluster))
    }

    pub fn for_compact(config: &Config) -> Result<Self, String> {
        let cluster = Arc::new(
            ClusterService::load_with_legacy(
                config.usage_db.clone(),
                Some(&config.cluster_state),
                config.cluster_node_name.as_deref(),
            )
            .map_err(|error| error.to_string())?,
        );
        Ok(Self::build(config, None, cluster))
    }

    pub fn with_cluster(
        config: &Config,
        history: Arc<History>,
        cluster: Arc<ClusterService>,
    ) -> Self {
        Self::build(config, Some(history), cluster)
    }

    fn build(config: &Config, history: Option<Arc<History>>, cluster: Arc<ClusterService>) -> Self {
        let timezone = cluster.effective_timezone();
        Self {
            scanner: SessionScanner::new_in(
                &config.claude_home,
                &config.codex_home,
                Some(timezone),
            ),
            quota: Arc::new(QuotaFetcher::new(
                config.claude_home.clone(),
                config.codex_home.clone(),
                config.statusline_cache.clone(),
                config.quota_fetch_s,
                store::QuotaStore::new_with_legacy(config.usage_db.clone(), &config.quota_cache),
            )),
            hooks: Arc::new(HookRegistry::default()),
            history,
            served_status: hooks::SharedStatus::default(),
            listener: None,
            listener_retry_at: None,
            claude_home: config.claude_home.clone(),
            codex_home: config.codex_home.clone(),
            backfill_started: false,
            backfill_tz: None,
            backfill_generation: Arc::new(AtomicU64::new(0)),
            backfill_running: Arc::new(AtomicBool::new(false)),
            cluster,
        }
    }

    /// The IANA zone used for daily buckets: the cluster zone when joined,
    /// otherwise this Linux host's local zone.
    fn bucket_timezone_id(&self) -> String {
        self.cluster.effective_timezone().name().to_string()
    }

    /// Backfills up to a year of daily history from old session logs off the
    /// poll thread; the stats page fills in when it completes. Re-runs when the
    /// bucket timezone changes (joining/leaving a cluster in another zone) so
    /// the stored days are rebucketed under the new zone — the mac-app's
    /// rebucket trigger, driven by the persisted `usage_bucket_timezone`.
    fn ensure_backfill(&mut self) {
        let Some(history) = self.history.as_ref().map(Arc::clone) else {
            return;
        };
        let timezone = self.cluster.effective_timezone();
        let timezone_id = timezone.name().to_string();
        let same_target = self.backfill_tz.as_deref() == Some(timezone_id.as_str());
        if same_target
            && (self.backfill_running.load(Ordering::Acquire)
                || history.bucket_timezone().as_deref() == Some(timezone_id.as_str())
                    && history.backfilled())
        {
            return;
        }
        if self.backfill_tz.is_some() && !same_target {
            // SessionScanner caches day buckets; a timezone change must drop
            // those caches before the next live scan.
            self.scanner =
                SessionScanner::new_in(&self.claude_home, &self.codex_home, Some(timezone));
        }
        self.backfill_started = true;
        self.backfill_tz = Some(timezone_id.clone());
        let generation = self.backfill_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let generation_guard = Arc::clone(&self.backfill_generation);
        self.backfill_running.store(true, Ordering::Release);
        let running = Arc::clone(&self.backfill_running);
        let claude_home = self.claude_home.clone();
        let codex_home = self.codex_home.clone();
        std::thread::spawn(move || {
            let cutoff = epoch_now() - BACKFILL_DAYS * 86_400;
            let (claude, codex) =
                sessions::full_daily_totals_in(&claude_home, &codex_home, cutoff, Some(timezone));
            let old_explained = history.bucket_timezone().and_then(|source| {
                if source == timezone_id {
                    return None;
                }
                source.parse().ok().map(|source_timezone| {
                    sessions::full_daily_totals_in(
                        &claude_home,
                        &codex_home,
                        cutoff,
                        Some(source_timezone),
                    )
                })
            });
            if generation_guard.load(Ordering::Acquire) != generation {
                return;
            }
            let today = chrono::Utc::now().with_timezone(&timezone).date_naive();
            let _ = history.apply_backfill(&timezone_id, claude, codex, old_explained, today);
            if generation_guard.load(Ordering::Acquire) == generation {
                running.store(false, Ordering::Release);
            }
        });
    }

    /// Bind failures (port taken, e.g. a mac-app bridge on the same machine)
    /// are non-fatal: state falls back to mtime detection alone.
    pub fn ensure_hook_listener(&mut self, address: &str) -> bool {
        if address.is_empty() {
            self.disable_hook_listener();
            return false;
        }
        if self.listener.is_some() {
            return true;
        }
        let now = Instant::now();
        if !listener_retry_due(self.listener_retry_at, now) {
            return false;
        }
        match hooks::spawn_listener(
            address,
            Arc::clone(&self.hooks),
            Arc::clone(&self.served_status),
            Arc::clone(&self.cluster),
        ) {
            Ok(listener) => {
                self.listener = Some(listener);
                self.listener_retry_at = None;
                true
            }
            Err(_) => {
                self.listener_retry_at = Some(now + LISTENER_RETRY_DELAY);
                false
            }
        }
    }

    /// Releases the listener socket and clears the last local response while
    /// the worker is displaying a remote source.
    pub fn disable_hook_listener(&mut self) {
        self.listener.take();
        self.listener_retry_at = None;
        *self
            .served_status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }

    pub fn collect(&mut self, force_quota: bool) -> Result<Snapshot, String> {
        if self.quota_due(force_quota) {
            self.refresh_quota();
        }
        self.snapshot_now()
    }

    pub fn quota_due(&self, force: bool) -> bool {
        self.quota.due(force)
    }

    /// Blocking provider API calls (up to 20 s each); used by `--once`.
    pub fn refresh_quota(&mut self) {
        self.quota.refresh();
    }

    /// Runs the blocking quota fetch on its own thread so the caller's poll
    /// loop keeps rendering fresh session data meanwhile; `due` stays false
    /// while the fetch is in flight.
    pub fn spawn_quota_refresh(&self) {
        let quota = Arc::clone(&self.quota);
        std::thread::spawn(move || quota.refresh());
    }

    /// Sessions scan plus the stored quota — never blocks on the network.
    pub fn snapshot_now(&mut self) -> Result<Snapshot, String> {
        self.snapshot(true)
    }

    /// Lightweight status-line collection: scans current sessions and reads
    /// the persisted quota cache, without provider requests or history work.
    pub fn snapshot_for_compact(&mut self) -> Result<Snapshot, String> {
        self.snapshot(false)
    }

    fn snapshot(&mut self, update_history: bool) -> Result<Snapshot, String> {
        if update_history {
            self.ensure_backfill();
        }
        let outcome = self.scanner.scan();
        let now = epoch_now();

        if update_history {
            let today = self.cluster.day_key(now);
            let timezone = self.bucket_timezone_id();
            if let Some(history) = &self.history {
                history.record_day_in("claude", &today, &outcome.claude.models, &timezone);
                history.record_day_in("codex", &today, &outcome.codex.models, &timezone);
                history.flush_if_dirty(now, self.cluster.today());
            }
        }

        let mut claude = provider_status(outcome.claude);
        apply_usage(&mut claude, &self.quota.claude(now), now);
        self.hooks.apply("claude", &mut claude, now);

        let mut codex = provider_status(outcome.codex);
        // Log-derived quota is the codex base; a live fetch overlays it.
        if let Some((observed_at, limits)) = &outcome.codex_rate_limits {
            let (primary, weekly) = quota::codex_log_windows(limits, now);
            set_windows(&mut codex, primary, weekly, now);
            codex.provider_usage_fetched_at = Some(*observed_at);
            codex.provider_usage_cached = true;
        }
        apply_usage(&mut codex, &self.quota.codex(now), now);
        self.hooks.apply("codex", &mut codex, now);

        let usage_fetched_at = claude
            .provider_usage_fetched_at
            .into_iter()
            .chain(codex.provider_usage_fetched_at)
            .max();
        let local = Snapshot {
            schema_version: 1,
            generated_at: Some(now),
            usage_fetched_at,
            cluster: None,
            claude,
            codex,
        };
        let snapshot = self.cluster.aggregate(&local, self.history.as_deref());
        if let Ok(serialized) = serde_json::to_string(&snapshot) {
            *self
                .served_status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(serialized);
        }
        Ok(snapshot)
    }
}

fn listener_retry_due(retry_at: Option<Instant>, now: Instant) -> bool {
    retry_at.is_none_or(|retry_at| now >= retry_at)
}

fn provider_status(scan: ProviderScan) -> ProviderStatus {
    ProviderStatus {
        status: scan.state.to_string(),
        tokens_today: scan.tokens_today,
        model_usage_today: scan.models,
        ..ProviderStatus::default()
    }
}

/// Port of StatusService.overlay: fetched windows replace log-derived ones only
/// when they carry a percentage, and the fetch error is always surfaced.
fn apply_usage(status: &mut ProviderStatus, usage: &ProviderUsage, now: i64) {
    if usage.primary.percent.is_some() {
        status.primary_pct = usage.primary.percent;
        status.primary_reset_min = usage.primary.reset_minutes(now);
    }
    if usage.weekly.percent.is_some() {
        status.weekly_pct = usage.weekly.percent;
        status.weekly_reset_min = usage.weekly.reset_minutes(now);
    }
    status.error = usage.error.clone();
    if usage.primary.percent.is_some() || usage.weekly.percent.is_some() {
        status.provider_usage_fetched_at = usage.fetched_at;
        status.provider_usage_cached = usage.is_cached;
    }
}

fn set_windows(status: &mut ProviderStatus, primary: UsageWindow, weekly: UsageWindow, now: i64) {
    status.primary_pct = primary.percent;
    status.primary_reset_min = primary.reset_minutes(now);
    status.weekly_pct = weekly.percent;
    status.weekly_reset_min = weekly.reset_minutes(now);
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};

    use super::*;
    use crate::source::SourceKind;

    fn test_config() -> Config {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "elink-tui-compact-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        Config {
            mode: SourceKind::Local,
            bridge_url: None,
            status_poll_s: 2.0,
            quota_fetch_s: 120,
            claude_home: root.join("claude"),
            codex_home: root.join("codex"),
            statusline_cache: root.join("statusline.json"),
            usage_db: root.join("usage.db"),
            quota_cache: root.join("quota.json"),
            history_cache: root.join("history.json"),
            cluster_state: root.join("cluster.json"),
            cluster_node_name: Some("test-node".to_string()),
            hook_listen: String::new(),
            device_url: None,
        }
    }

    #[test]
    fn compact_source_has_no_history_and_skips_backfill() {
        let config = test_config();
        let mut source = LocalSource::for_compact(&config).expect("cluster state loads");

        assert!(source.history.is_none());

        source
            .snapshot_for_compact()
            .expect("compact snapshot should scan local sessions");

        assert!(!source.backfill_started);
    }

    #[test]
    fn listener_retry_gate_opens_after_delay() {
        let now = Instant::now();

        assert!(!listener_retry_due(Some(now + LISTENER_RETRY_DELAY), now));
        assert!(listener_retry_due(
            Some(now + LISTENER_RETRY_DELAY),
            now + LISTENER_RETRY_DELAY
        ));
        assert!(listener_retry_due(None, now));
    }
}
