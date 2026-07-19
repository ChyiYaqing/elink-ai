use std::fs;
use std::path::PathBuf;
use std::time::{Duration, UNIX_EPOCH};

use serde_json::Value;

use super::creds;
use crate::util::epoch_now;

const WEEKLY_WINDOW_SECONDS: i64 = 6 * 24 * 60 * 60;
const STATUSLINE_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;

/// One quota window. `reset_at` survives expiry so keep-last-good can compare
/// freshness, but `percent` is cleared once `reset_at <= now` — the UI renders
/// unknown windows as "—", never 0 (mirrors Models.swift `discardingIfExpired`).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct UsageWindow {
    pub percent: Option<f64>,
    pub reset_at: Option<i64>,
}

impl UsageWindow {
    pub fn discard_if_expired(mut self, now: i64) -> Self {
        if let Some(reset_at) = self.reset_at {
            if reset_at <= now {
                self.percent = None;
            }
        }
        self
    }

    pub fn reset_minutes(&self, now: i64) -> Option<i64> {
        self.reset_at
            .filter(|value| *value > now)
            .map(|value| (value - now) / 60)
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProviderUsage {
    pub primary: UsageWindow,
    pub weekly: UsageWindow,
    pub error: Option<String>,
    pub fetched_at: Option<i64>,
    pub is_cached: bool,
}

impl ProviderUsage {
    fn with_error(error: impl Into<String>) -> Self {
        Self {
            error: Some(error.into()),
            ..Self::default()
        }
    }

    pub fn discarding_expired(&self, now: i64) -> Self {
        let mut value = self.clone();
        value.primary = value.primary.discard_if_expired(now);
        value.weekly = value.weekly.discard_if_expired(now);
        value
    }
}

/// Anthropic `five_hour`/`seven_day` object: `utilization` + ISO8601 `resets_at`.
fn iso_window(value: &Value, now: i64) -> UsageWindow {
    let Some(object) = value.as_object() else {
        return UsageWindow::default();
    };
    UsageWindow {
        percent: object.get("utilization").and_then(Value::as_f64),
        reset_at: object
            .get("resets_at")
            .and_then(Value::as_str)
            .and_then(parse_iso_epoch),
    }
    .discard_if_expired(now)
}

/// wham `primary_window`/`secondary_window` object: `used_percent` + epoch `reset_at`.
fn epoch_window(value: &Value, now: i64) -> UsageWindow {
    let Some(object) = value.as_object() else {
        return UsageWindow::default();
    };
    UsageWindow {
        percent: object.get("used_percent").and_then(Value::as_f64),
        reset_at: object.get("reset_at").and_then(number_as_i64),
    }
    .discard_if_expired(now)
}

pub fn parse_iso_epoch(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.timestamp())
}

fn number_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|value| value as i64))
}

/// Classifies wham windows: `limit_window_seconds >= 6 days` means weekly,
/// shorter means primary; without the field, index 0 is primary and 1 weekly.
pub fn codex_windows(limits: &Value, now: i64) -> (UsageWindow, UsageWindow) {
    let mut primary = UsageWindow::default();
    let mut weekly = UsageWindow::default();
    let values = [limits.get("primary_window"), limits.get("secondary_window")];
    for (index, value) in values.into_iter().enumerate() {
        let Some(value) = value.filter(|value| value.is_object()) else {
            continue;
        };
        let window = epoch_window(value, now);
        match value.get("limit_window_seconds").and_then(number_as_i64) {
            Some(seconds) if seconds >= WEEKLY_WINDOW_SECONDS => weekly = window,
            Some(_) => primary = window,
            None if index == 0 => primary = window,
            None => weekly = window,
        }
    }
    (primary, weekly)
}

/// Converts the `payload.rate_limits` shape found in Codex session logs
/// (`primary`/`secondary`, `window_minutes`, `resets_at`) into the wham shape
/// and reuses `codex_windows`.
pub fn codex_log_windows(limits: &Value, now: i64) -> (UsageWindow, UsageWindow) {
    let mut converted = serde_json::Map::new();
    for (source, target) in [
        ("primary", "primary_window"),
        ("secondary", "secondary_window"),
    ] {
        let Some(window) = limits.get(source).and_then(Value::as_object) else {
            continue;
        };
        let mut window = window.clone();
        if let Some(minutes) = window.get("window_minutes").and_then(number_as_i64) {
            window.insert(
                "limit_window_seconds".to_string(),
                Value::from(minutes * 60),
            );
        }
        if let Some(reset) = window.get("resets_at").cloned() {
            window.insert("reset_at".to_string(), reset);
        }
        converted.insert(target.to_string(), Value::Object(window));
    }
    codex_windows(&Value::Object(converted), now)
}

/// `~/.cache/statusline/last.json` fallback:
/// `rate_limits.{five_hour,seven_day}.{used_percentage, resets_at(epoch)}`.
pub fn statusline_usage(json: &Value, fetched_at: i64, now: i64) -> Option<ProviderUsage> {
    let limits = json.get("rate_limits")?.as_object()?;
    let window = |key: &str| -> UsageWindow {
        let Some(object) = limits.get(key).and_then(Value::as_object) else {
            return UsageWindow::default();
        };
        UsageWindow {
            percent: object.get("used_percentage").and_then(Value::as_f64),
            reset_at: object.get("resets_at").and_then(number_as_i64),
        }
        .discard_if_expired(now)
    };
    let primary = window("five_hour");
    let weekly = window("seven_day");
    if primary.percent.is_none() && weekly.percent.is_none() {
        return None;
    }
    Some(ProviderUsage {
        primary,
        weekly,
        error: None,
        fetched_at: Some(fetched_at),
        is_cached: true,
    })
}

/// Retains the previous good windows when a fetch fails or a stale cache would
/// overwrite fresher in-memory data (port of UsageFetcher.keepLastGood).
pub fn keep_last_good(old: &ProviderUsage, new: ProviderUsage, now: i64) -> ProviderUsage {
    let mut current = new;
    current.primary = current.primary.discard_if_expired(now);
    current.weekly = current.weekly.discard_if_expired(now);
    let previous_primary = old.primary.discard_if_expired(now);
    let previous_weekly = old.weekly.discard_if_expired(now);
    let had_good_value = previous_primary.percent.is_some() || previous_weekly.percent.is_some();
    let retain = |error: Option<String>| ProviderUsage {
        primary: previous_primary,
        weekly: previous_weekly,
        error,
        fetched_at: old.fetched_at,
        is_cached: true,
    };
    if current.is_cached && had_good_value {
        if let (Some(new_fetched), Some(old_fetched)) = (current.fetched_at, old.fetched_at) {
            if old_fetched > new_fetched {
                return retain(current.error);
            }
        }
    }
    if current.primary.percent.is_none() && current.weekly.percent.is_none() && had_good_value {
        return retain(current.error);
    }
    current
}

#[derive(Default)]
struct QuotaState {
    stored_claude: ProviderUsage,
    stored_codex: ProviderUsage,
    last_timer: i64,
    next_allowed: i64,
    /// Mirrors UsageFetcher's `fetching` flag: one refresh at a time.
    fetching: bool,
}

/// All mutable state lives behind one mutex so a slow `refresh` (network,
/// no lock held) can run on its own thread while readers keep serving the
/// last stored windows.
pub struct QuotaFetcher {
    agent: ureq::Agent,
    claude_home: PathBuf,
    codex_home: PathBuf,
    statusline_cache: PathBuf,
    quota_fetch_s: u64,
    store: super::store::QuotaStore,
    state: std::sync::Mutex<QuotaState>,
}

impl QuotaFetcher {
    pub fn new(
        claude_home: PathBuf,
        codex_home: PathBuf,
        statusline_cache: PathBuf,
        quota_fetch_s: u64,
        store: super::store::QuotaStore,
    ) -> Self {
        let now = epoch_now();
        let state = QuotaState {
            stored_claude: store.load("claude", now).unwrap_or_default(),
            stored_codex: store.load("codex", now).unwrap_or_default(),
            ..QuotaState::default()
        };
        Self {
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(20))
                .build(),
            claude_home,
            codex_home,
            statusline_cache,
            quota_fetch_s,
            store,
            state: std::sync::Mutex::new(state),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, QuotaState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn claude(&self, now: i64) -> ProviderUsage {
        self.state().stored_claude.discarding_expired(now)
    }

    pub fn codex(&self, now: i64) -> ProviderUsage {
        self.state().stored_codex.discarding_expired(now)
    }

    /// True when the 120 s timer elapsed and the 60 s floor (300 s after
    /// HTTP 429) allows another attempt; `force` bypasses both. Never true
    /// while a refresh is already in flight.
    pub fn due(&self, force: bool) -> bool {
        let state = self.state();
        if state.fetching {
            return false;
        }
        if force {
            return true;
        }
        let now = epoch_now();
        let interval = i64::try_from(self.quota_fetch_s).unwrap_or(i64::MAX);
        (state.last_timer == 0 || now >= state.last_timer.saturating_add(interval))
            && now >= state.next_allowed
    }

    /// Blocking network calls run without the lock; readers see the previous
    /// windows until the results land.
    pub fn refresh(&self) {
        {
            let mut state = self.state();
            if state.fetching {
                return;
            }
            state.fetching = true;
            state.last_timer = epoch_now();
        }
        let now = epoch_now();
        let claude = self.fetch_claude(now);
        let codex = self.fetch_codex(now);
        let rate_limited = [&claude.error, &codex.error]
            .into_iter()
            .flatten()
            .any(|error| error.contains("429"));
        self.store.save("claude", &claude);
        self.store.save("codex", &codex);
        let mut state = self.state();
        state.next_allowed = now + if rate_limited { 300 } else { 60 };
        state.stored_claude = keep_last_good(&state.stored_claude, claude, now);
        state.stored_codex = keep_last_good(&state.stored_codex, codex, now);
        state.fetching = false;
    }

    fn fetch_claude(&self, now: i64) -> ProviderUsage {
        let token = match creds::claude_token(&self.claude_home) {
            Ok(token) => token,
            Err(error) => {
                return self.claude_fallback(
                    format!("{error}; showing statusline cache"),
                    &error,
                    now,
                )
            }
        };
        let response = self
            .agent
            .get("https://api.anthropic.com/api/oauth/usage")
            .set("Authorization", &format!("Bearer {token}"))
            .set("anthropic-beta", "oauth-2025-04-20")
            .set("Accept", "application/json")
            .call();
        let json: Value = match response {
            Ok(response) => match response.into_json() {
                Ok(json) => json,
                Err(_) => {
                    let error = "claude usage response parse failed";
                    return self.claude_fallback(error.to_string(), error, now);
                }
            },
            Err(ureq::Error::Status(code, _)) => {
                let error = format!("claude usage HTTP {code}");
                return self.claude_fallback(error.clone(), &error, now);
            }
            Err(ureq::Error::Transport(_)) => {
                let error = "claude usage request failed";
                return self.claude_fallback(error.to_string(), error, now);
            }
        };
        ProviderUsage {
            primary: iso_window(&json["five_hour"], now),
            weekly: iso_window(&json["seven_day"], now),
            error: None,
            fetched_at: Some(now),
            is_cached: false,
        }
    }

    /// On failure, falls back to the statusline cache when it is usable;
    /// `cache_error` annotates the cached value, `plain_error` is used alone.
    fn claude_fallback(&self, cache_error: String, plain_error: &str, now: i64) -> ProviderUsage {
        match self.cached_claude_usage(now) {
            Some(mut cached) => {
                cached.error = Some(cache_error);
                cached
            }
            None => ProviderUsage::with_error(plain_error),
        }
    }

    fn cached_claude_usage(&self, now: i64) -> Option<ProviderUsage> {
        let metadata = fs::metadata(&self.statusline_cache).ok()?;
        let modified = metadata
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs() as i64;
        if modified > now {
            return None;
        }
        let data = fs::read(&self.statusline_cache).ok()?;
        let json: Value = serde_json::from_slice(&data).ok()?;
        let usage = statusline_usage(&json, modified, now)?;
        let has_reset_time = usage.primary.reset_at.is_some() || usage.weekly.reset_at.is_some();
        if !has_reset_time && now - modified > STATUSLINE_MAX_AGE_SECONDS {
            return None;
        }
        Some(usage)
    }

    fn fetch_codex(&self, now: i64) -> ProviderUsage {
        let (token, account) = match creds::codex_credentials(&self.codex_home) {
            Ok(value) => value,
            Err(error) => return ProviderUsage::with_error(error),
        };
        let mut request = self
            .agent
            .get("https://chatgpt.com/backend-api/wham/usage")
            .set("Authorization", &format!("Bearer {token}"))
            .set("Accept", "application/json");
        if let Some(account) = &account {
            request = request.set("ChatGPT-Account-Id", account);
        }
        let json: Value = match request.call() {
            Ok(response) => match response.into_json() {
                Ok(json) => json,
                Err(_) => return ProviderUsage::with_error("codex usage response parse failed"),
            },
            Err(ureq::Error::Status(401 | 403, _)) => {
                return ProviderUsage::with_error("codex credentials expired; run codex to log in")
            }
            Err(ureq::Error::Status(429, _)) => {
                return ProviderUsage::with_error("codex usage HTTP 429; retrying later")
            }
            Err(ureq::Error::Status(code, _)) => {
                return ProviderUsage::with_error(format!("codex usage HTTP {code}"))
            }
            Err(ureq::Error::Transport(_)) => {
                return ProviderUsage::with_error("codex usage request failed")
            }
        };
        let Some(limits) = json.get("rate_limit").filter(|value| value.is_object()) else {
            return ProviderUsage::with_error("codex usage response parse failed");
        };
        let (primary, weekly) = codex_windows(limits, now);
        ProviderUsage {
            primary,
            weekly,
            error: None,
            fetched_at: Some(now),
            is_cached: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: i64 = 1_783_933_200;

    #[test]
    fn parses_anthropic_windows() {
        let json = json!({
            "five_hour": {"utilization": 43.0, "resets_at": "2026-07-18T12:00:00Z"},
            "seven_day": {"utilization": 68.0, "resets_at": "2026-07-21T00:00:00.500Z"}
        });
        let now = parse_iso_epoch("2026-07-18T10:00:00Z").unwrap();
        let primary = iso_window(&json["five_hour"], now);
        assert_eq!(primary.percent, Some(43.0));
        assert_eq!(primary.reset_minutes(now), Some(120));
        let weekly = iso_window(&json["seven_day"], now);
        assert_eq!(weekly.percent, Some(68.0));
    }

    #[test]
    fn discards_expired_windows() {
        let json = json!({"utilization": 43.0, "resets_at": "2026-07-18T09:00:00Z"});
        let now = parse_iso_epoch("2026-07-18T10:00:00Z").unwrap();
        let window = iso_window(&json, now);
        assert_eq!(window.percent, None);
        assert_eq!(window.reset_minutes(now), None);
    }

    #[test]
    fn classifies_codex_windows_by_window_seconds() {
        let limits = json!({
            "primary_window": {
                "used_percent": 22.0, "reset_at": NOW + 8729 * 60,
                "limit_window_seconds": 7 * 24 * 60 * 60
            },
            "secondary_window": {
                "used_percent": 12.0, "reset_at": NOW + 144 * 60,
                "limit_window_seconds": 5 * 60 * 60
            }
        });
        let (primary, weekly) = codex_windows(&limits, NOW);
        assert_eq!(primary.percent, Some(12.0));
        assert_eq!(weekly.percent, Some(22.0));
    }

    #[test]
    fn classifies_codex_windows_by_index_without_window_seconds() {
        let limits = json!({
            "primary_window": {"used_percent": 12.0, "reset_at": NOW + 600},
            "secondary_window": {"used_percent": 22.0, "reset_at": NOW + 6000}
        });
        let (primary, weekly) = codex_windows(&limits, NOW);
        assert_eq!(primary.percent, Some(12.0));
        assert_eq!(weekly.percent, Some(22.0));
    }

    #[test]
    fn converts_codex_log_rate_limits() {
        let limits = json!({
            "primary": {"used_percent": 12.0, "window_minutes": 300, "resets_at": NOW + 600},
            "secondary": {"used_percent": 22.0, "window_minutes": 10080, "resets_at": NOW + 6000}
        });
        let (primary, weekly) = codex_log_windows(&limits, NOW);
        assert_eq!(primary.percent, Some(12.0));
        assert_eq!(weekly.percent, Some(22.0));
    }

    #[test]
    fn parses_statusline_cache() {
        let json = json!({
            "rate_limits": {
                "five_hour": {"used_percentage": 43.0, "resets_at": NOW + 600},
                "seven_day": {"used_percentage": 68.0, "resets_at": NOW + 60000}
            }
        });
        let usage = statusline_usage(&json, NOW - 100, NOW).unwrap();
        assert_eq!(usage.primary.percent, Some(43.0));
        assert_eq!(usage.weekly.percent, Some(68.0));
        assert!(usage.is_cached);
        assert!(statusline_usage(&json!({}), NOW, NOW).is_none());
    }

    #[test]
    fn keep_last_good_retains_previous_windows_on_failure() {
        let old = ProviderUsage {
            primary: UsageWindow {
                percent: Some(43.0),
                reset_at: Some(NOW + 600),
            },
            weekly: UsageWindow {
                percent: Some(68.0),
                reset_at: Some(NOW + 60000),
            },
            error: None,
            fetched_at: Some(NOW - 120),
            is_cached: false,
        };
        let new = ProviderUsage::with_error("claude usage request failed");
        let kept = keep_last_good(&old, new, NOW);
        assert_eq!(kept.primary.percent, Some(43.0));
        assert_eq!(kept.error.as_deref(), Some("claude usage request failed"));
        assert!(kept.is_cached);
    }

    #[test]
    fn keep_last_good_prefers_fresher_memory_over_older_cache() {
        let old = ProviderUsage {
            primary: UsageWindow {
                percent: Some(43.0),
                reset_at: Some(NOW + 600),
            },
            weekly: UsageWindow::default(),
            error: None,
            fetched_at: Some(NOW - 60),
            is_cached: false,
        };
        let stale_cache = ProviderUsage {
            primary: UsageWindow {
                percent: Some(10.0),
                reset_at: Some(NOW + 600),
            },
            weekly: UsageWindow::default(),
            error: Some("claude usage HTTP 500".to_string()),
            fetched_at: Some(NOW - 3600),
            is_cached: true,
        };
        let kept = keep_last_good(&old, stale_cache, NOW);
        assert_eq!(kept.primary.percent, Some(43.0));
        assert!(kept.is_cached);
        assert_eq!(kept.error.as_deref(), Some("claude usage HTTP 500"));
    }

    #[test]
    fn keep_last_good_drops_expired_previous_windows() {
        let old = ProviderUsage {
            primary: UsageWindow {
                percent: Some(43.0),
                reset_at: Some(NOW - 10),
            },
            weekly: UsageWindow::default(),
            error: None,
            fetched_at: Some(NOW - 7200),
            is_cached: false,
        };
        let new = ProviderUsage::with_error("claude usage request failed");
        let kept = keep_last_good(&old, new, NOW);
        assert_eq!(kept.primary.percent, None);
        assert_eq!(kept.error.as_deref(), Some("claude usage request failed"));
    }

    #[test]
    fn huge_fetch_interval_does_not_overflow_after_first_fetch() {
        let fetcher = QuotaFetcher::new(
            PathBuf::new(),
            PathBuf::new(),
            PathBuf::new(),
            u64::MAX,
            super::super::store::QuotaStore::new(PathBuf::new()),
        );
        fetcher.state().last_timer = epoch_now();

        assert!(!fetcher.due(false));
    }

    #[test]
    fn due_is_false_while_a_refresh_is_in_flight() {
        let fetcher = QuotaFetcher::new(
            PathBuf::new(),
            PathBuf::new(),
            PathBuf::new(),
            120,
            super::super::store::QuotaStore::new(PathBuf::new()),
        );
        assert!(fetcher.due(false));
        fetcher.state().fetching = true;

        assert!(!fetcher.due(false));
        assert!(!fetcher.due(true));
    }
}
