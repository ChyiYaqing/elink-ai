use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use serde_json::Value;

use super::creds;
use crate::util::epoch_now;

const WEEKLY_WINDOW_SECONDS: i64 = 6 * 24 * 60 * 60;
const GEMINI_WEEKLY_THRESHOLD_SECONDS: i64 = 26 * 60 * 60;
const GEMINI_CODE_ASSIST_BASE_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal";

/// Resolves the Gemini CLI desktop OAuth client credentials at runtime from
/// environment variables or the locally installed `@google/gemini-cli` bundle
/// so no third-party client secret is ever committed to the repository.
fn gemini_oauth_client_config() -> Option<(String, String)> {
    if let (Ok(id), Ok(secret)) = (
        std::env::var("GEMINI_OAUTH_CLIENT_ID"),
        std::env::var("GEMINI_OAUTH_CLIENT_SECRET"),
    ) {
        if !id.is_empty() && !secret.is_empty() {
            return Some((id, secret));
        }
    }
    let path_var = std::env::var_os("PATH");
    for dir in gemini_cli_bundle_dirs(dirs::home_dir().as_deref(), path_var.as_deref()) {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.ends_with(".js") {
                continue;
            }
            let Ok(text) = fs::read_to_string(entry.path()) else {
                continue;
            };
            if !text.contains("OAUTH_CLIENT_SECRET") {
                continue;
            }
            if let (Some(id), Some(secret)) = (
                extract_js_string_const(&text, "OAUTH_CLIENT_ID"),
                extract_js_string_const(&text, "OAUTH_CLIENT_SECRET"),
            ) {
                return Some((id, secret));
            }
        }
    }
    None
}

/// Bundle directories that may hold `@google/gemini-cli`. The `gemini`
/// symlinks on PATH and in the usual bin directories are followed first
/// (Homebrew formula, ~/.npm-global, ...), then the default global npm,
/// Homebrew Cellar and nvm / volta / fnm locations are added.
fn gemini_cli_bundle_dirs(home: Option<&Path>, path_var: Option<&OsStr>) -> Vec<PathBuf> {
    const PKG: &str = "@google/gemini-cli";
    fn children(dir: &Path) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = fs::read_dir(dir)
            .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
            .unwrap_or_default();
        out.sort_unstable_by(|a, b| b.cmp(a));
        out
    }
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut add = |dir: PathBuf| {
        if dir.is_dir() && !dirs.contains(&dir) {
            dirs.push(dir);
        }
    };
    let mut bins: Vec<PathBuf> = path_var
        .map(|value| std::env::split_paths(value).collect())
        .unwrap_or_default();
    bins.extend(
        [
            "/usr/local/bin",
            "/usr/bin",
            "/opt/homebrew/bin",
            "/home/linuxbrew/.linuxbrew/bin",
        ]
        .map(PathBuf::from),
    );
    if let Some(home) = home {
        bins.extend([home.join(".local/bin"), home.join(".npm-global/bin")]);
    }
    for bin in bins {
        let Ok(real) = fs::canonicalize(bin.join("gemini")) else {
            continue;
        };
        let real = real.to_string_lossy();
        if let Some(idx) = real.find(&format!("/{PKG}/")) {
            add(PathBuf::from(format!("{}/{PKG}/bundle", &real[..idx])));
        }
    }
    let mut roots: Vec<PathBuf> = [
        "/usr/local/lib/node_modules",
        "/usr/lib/node_modules",
        "/opt/homebrew/lib/node_modules",
        "/home/linuxbrew/.linuxbrew/lib/node_modules",
    ]
    .map(PathBuf::from)
    .to_vec();
    for cellar in [
        "/opt/homebrew/Cellar/gemini-cli",
        "/usr/local/Cellar/gemini-cli",
        "/home/linuxbrew/.linuxbrew/Cellar/gemini-cli",
    ] {
        roots.extend(
            children(Path::new(cellar))
                .into_iter()
                .map(|v| v.join("libexec/lib/node_modules")),
        );
    }
    if let Some(home) = home {
        roots.push(home.join(".npm-global/lib/node_modules"));
        roots.push(
            home.join(".volta/tools/image/packages")
                .join(PKG)
                .join("lib/node_modules"),
        );
        roots.extend(
            children(&home.join(".nvm/versions/node"))
                .into_iter()
                .map(|v| v.join("lib/node_modules")),
        );
        for fnm in [
            ".local/share/fnm/node-versions",
            "Library/Application Support/fnm/node-versions",
        ] {
            roots.extend(
                children(&home.join(fnm))
                    .into_iter()
                    .map(|v| v.join("installation/lib/node_modules")),
            );
        }
    }
    for root in roots {
        add(root.join(PKG).join("bundle"));
    }
    dirs
}

/// Finds `NAME = "value"` (or single-quoted). Every occurrence is tried, not
/// just the first: the name can appear in a reference such as
/// `clientId: OAUTH_CLIENT_ID` before its declaration.
fn extract_js_string_const(text: &str, name: &str) -> Option<String> {
    text.match_indices(name).find_map(|(idx, _)| {
        let rest = text[idx + name.len()..].trim_start();
        let rest = rest.strip_prefix('=')?.trim_start();
        let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'')?;
        let body = &rest[1..];
        let value = &body[..body.find(quote)?];
        (!value.is_empty()).then(|| value.to_string())
    })
}
const STATUSLINE_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
/// The Antigravity statusLine cache only refreshes while `agy` runs. Within
/// this age it is used as is; past it the Code Assist API is asked first and the
/// cache is only a fallback, so the weekly figure cannot freeze at an old value.
const ANTIGRAVITY_CACHE_FRESH_SECONDS: i64 = 10 * 60;
/// Fallback when the installed Claude Code version cannot be resolved: a
/// slightly stale version is harmless, a missing User-Agent is not.
const FALLBACK_CLAUDE_CODE_VERSION: &str = "2.1.0";

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

/// Pay-as-you-go pool on top of the subscription (Claude's `extra_usage`,
/// Codex's spend-control limit).
///
/// Claude reports minor units and says how far to shift via `decimal_places`;
/// the amounts here are already converted, and rendering the raw
/// `monthly_limit` would overstate the cap a hundredfold.
///
/// `unit` is either an ISO currency code or `credits` — Codex counts its limit
/// in credits, and putting a `$` in front of those calls credits dollars. The
/// unit therefore travels with the number.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExtraUsage {
    pub used: f64,
    pub limit: f64,
    pub percent: f64,
    pub unit: Unit,
}

pub const CREDITS_UNIT: &str = "credits";

/// What an extra-usage figure is counted in. Only the rendering differs, so the
/// code is kept inline rather than pulling in a currency crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    Currency([u8; 3]),
    Credits,
}

impl Unit {
    pub const USD: Self = Self::Currency(*b"USD");

    pub fn parse(value: &str) -> Self {
        let trimmed = value.trim();
        if trimmed.eq_ignore_ascii_case(CREDITS_UNIT) {
            return Self::Credits;
        }
        let bytes = trimmed.as_bytes();
        match bytes.len() {
            3 => Self::Currency([
                bytes[0].to_ascii_uppercase(),
                bytes[1].to_ascii_uppercase(),
                bytes[2].to_ascii_uppercase(),
            ]),
            _ => Self::USD,
        }
    }

    pub fn code(&self) -> &str {
        match self {
            Self::Currency(code) => std::str::from_utf8(code).unwrap_or("USD"),
            Self::Credits => CREDITS_UNIT,
        }
    }
}

/// A weekly limit scoped to one model, e.g. the separate Opus allowance on Max
/// plans. Kept apart from `weekly`: that is the account-wide total, and folding
/// them together would hide "plenty left overall but Opus is exhausted".
#[derive(Debug, Clone, PartialEq)]
pub struct ScopedLimit {
    pub id: String,
    pub title: String,
    pub window: UsageWindow,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProviderUsage {
    pub primary: UsageWindow,
    pub weekly: UsageWindow,
    pub scoped_limits: Vec<ScopedLimit>,
    pub extra_usage: Option<ExtraUsage>,
    /// Credits still on the account (Codex's `credits.balance`). Only set when
    /// the API says the account actually has a credit pool — hanging a
    /// "balance 0" row on every Plus user is noise.
    pub credit_balance: Option<f64>,
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
        value.scoped_limits.retain_mut(|limit| {
            limit.window = limit.window.discard_if_expired(now);
            limit.window.percent.is_some()
        });
        value
    }
}

/// The wham usage payload, everything the panel shows in one place.
pub fn codex_usage(json: &Value, fetched_at: i64, now: i64) -> ProviderUsage {
    let (primary, weekly) = codex_windows(&json["rate_limit"], now);
    ProviderUsage {
        primary,
        weekly,
        scoped_limits: codex_scoped_limits(json, now),
        extra_usage: codex_extra_usage(json),
        credit_balance: codex_credit_balance(json),
        fetched_at: Some(fetched_at),
        ..ProviderUsage::default()
    }
}

/// Parses Gemini Code Assist `retrieveUserQuota` buckets into 5-hour (`primary`),
/// weekly (`weekly`), and per-tier `scoped_limits`. Missing windows stay `None`,
/// never zero.
pub fn gemini_usage(json: &Value, fetched_at: i64, now: i64) -> ProviderUsage {
    let raw_buckets = json["buckets"]
        .as_array()
        .or_else(|| json["quotas"].as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    struct ParsedBucket {
        group_id: String,
        title: String,
        is_weekly: bool,
        window: UsageWindow,
    }

    let mut parsed = Vec::new();
    for bucket in raw_buckets {
        let Some(remaining) = flexible_f64(&bucket["remainingFraction"]) else {
            continue;
        };
        let used_percent = ((1.0 - remaining.clamp(0.0, 1.0)) * 100.0).clamp(0.0, 100.0);
        let reset_at = bucket["resetTime"].as_str().and_then(parse_iso_epoch);
        let window = UsageWindow {
            percent: Some(used_percent),
            reset_at,
        }
        .discard_if_expired(now);
        if window.percent.is_none() {
            continue;
        }
        let model_id = bucket["modelId"].as_str().unwrap_or("").trim();
        let is_weekly = is_gemini_weekly_bucket(bucket, reset_at, now);
        let (group_id, title) = gemini_tier_group(model_id);
        parsed.push(ParsedBucket {
            group_id,
            title,
            is_weekly,
            window,
        });
    }

    let pick_worst = |weekly: bool| -> UsageWindow {
        parsed
            .iter()
            .filter(|item| item.is_weekly == weekly)
            .map(|item| item.window)
            .max_by(|lhs, rhs| {
                let lp = lhs.percent.unwrap_or(-1.0);
                let rp = rhs.percent.unwrap_or(-1.0);
                lp.total_cmp(&rp).then_with(|| {
                    let lr = lhs.reset_at.unwrap_or(i64::MAX);
                    let rr = rhs.reset_at.unwrap_or(i64::MAX);
                    rr.cmp(&lr)
                })
            })
            .unwrap_or_default()
    };

    let primary = pick_worst(false);
    let weekly = pick_worst(true);

    let mut grouped: std::collections::HashMap<String, (String, bool, UsageWindow)> =
        std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for item in &parsed {
        if item.group_id.is_empty() {
            continue;
        }
        let key = format!(
            "{}:{}",
            item.group_id,
            if item.is_weekly { "w" } else { "p" }
        );
        match grouped.get_mut(&key) {
            Some(existing) => {
                if item.window.percent.unwrap_or(-1.0) > existing.2.percent.unwrap_or(-1.0) {
                    *existing = (item.title.clone(), item.is_weekly, item.window);
                }
            }
            None => {
                order.push(key.clone());
                grouped.insert(key, (item.title.clone(), item.is_weekly, item.window));
            }
        }
    }
    let mut scoped_limits = Vec::new();
    if order.len() > 1 {
        for key in order {
            if let Some((title, is_weekly, window)) = grouped.get(&key) {
                let suffix = if *is_weekly { " weekly" } else { "" };
                scoped_limits.push(ScopedLimit {
                    id: key,
                    title: format!("{title}{suffix}"),
                    window: *window,
                });
            }
        }
    }

    ProviderUsage {
        primary,
        weekly,
        scoped_limits,
        fetched_at: Some(fetched_at),
        ..ProviderUsage::default()
    }
}

fn is_gemini_weekly_bucket(bucket: &Value, reset_at: Option<i64>, now: i64) -> bool {
    if let Some(seconds) = flexible_f64(&bucket["limitWindowSeconds"])
        .or_else(|| flexible_f64(&bucket["limit_window_seconds"]))
        .or_else(|| flexible_f64(&bucket["windowSeconds"]))
    {
        return seconds > 24.0 * 3600.0;
    }
    for key in ["window", "duration", "quotaWindow", "windowType", "period"] {
        if let Some(text) = bucket[key].as_str() {
            let lower = text.to_lowercase();
            if lower.contains("week")
                || lower.contains("7d")
                || lower.contains("seven_day")
                || lower.contains("168h")
            {
                return true;
            }
            if lower.contains("5h")
                || lower.contains("5_hour")
                || lower.contains("five_hour")
                || lower.contains("daily")
                || lower.contains("24h")
            {
                return false;
            }
        }
    }
    reset_at.is_some_and(|reset| reset - now > GEMINI_WEEKLY_THRESHOLD_SECONDS)
}

fn gemini_tier_group(model_id: &str) -> (String, String) {
    let lower = model_id.to_lowercase();
    if lower.is_empty() {
        return (String::new(), String::new());
    }
    if lower.contains("flash-lite") || lower.contains("flash_lite") {
        return ("flash-lite".to_string(), "Flash Lite".to_string());
    }
    if lower.contains("flash") {
        return ("flash".to_string(), "Flash".to_string());
    }
    if lower.contains("pro") {
        return ("pro".to_string(), "Pro".to_string());
    }
    let cleaned = model_id.strip_prefix("gemini-").unwrap_or(model_id);
    (lower, cleaned.to_string())
}

/// Parses Antigravity CLI `statusLine` JSON (`quota` map keyed by bucket ID
/// such as `gemini-5h` and `gemini-weekly`).
pub fn antigravity_statusline_gemini_usage(
    json: &Value,
    fetched_at: i64,
    now: i64,
) -> ProviderUsage {
    let Some(quota) = json["quota"].as_object() else {
        return ProviderUsage::default();
    };
    let mut keys: Vec<&String> = quota.keys().collect();
    keys.sort();
    let mut primary_windows = Vec::new();
    let mut weekly_windows = Vec::new();
    let mut scoped_limits = Vec::new();

    for key in keys {
        let lower = key.to_lowercase();
        if !lower.contains("gemini") {
            continue;
        }
        let entry = &quota[key];
        if entry["disabled"].as_bool() == Some(true) {
            continue;
        }
        let Some(remaining) = flexible_f64(&entry["remaining_fraction"])
            .or_else(|| flexible_f64(&entry["remainingFraction"]))
        else {
            continue;
        };
        let used_percent = ((1.0 - remaining.clamp(0.0, 1.0)) * 100.0).clamp(0.0, 100.0);
        let reset_in_seconds = flexible_f64(&entry["reset_in_seconds"])
            .or_else(|| flexible_f64(&entry["resetInSeconds"]));
        let reset_at = entry["reset_time"]
            .as_str()
            .or_else(|| entry["resetTime"].as_str())
            .and_then(parse_iso_epoch)
            .or_else(|| {
                reset_in_seconds
                    .filter(|s| *s > 0.0)
                    .map(|s| fetched_at + s as i64)
            });
        let window = UsageWindow {
            percent: Some(used_percent),
            reset_at,
        }
        .discard_if_expired(now);
        if window.percent.is_none() {
            continue;
        }
        let is_weekly = if lower.contains("week")
            || lower.contains("7d")
            || lower.contains("seven_day")
        {
            true
        } else if lower.contains("5h") || lower.contains("5_hour") || lower.contains("five_hour") {
            false
        } else if let Some(reset) = reset_at {
            reset - now > GEMINI_WEEKLY_THRESHOLD_SECONDS
        } else {
            reset_in_seconds.is_some_and(|s| s > GEMINI_WEEKLY_THRESHOLD_SECONDS as f64)
        };
        if is_weekly {
            weekly_windows.push(window);
        } else {
            primary_windows.push(window);
        }
        if lower != "gemini-5h" && lower != "gemini-weekly" {
            scoped_limits.push(ScopedLimit {
                id: key.clone(),
                title: key.clone(),
                window,
            });
        }
    }

    let pick_worst = |windows: &[UsageWindow]| -> UsageWindow {
        windows
            .iter()
            .copied()
            .max_by(|lhs, rhs| {
                let lp = lhs.percent.unwrap_or(-1.0);
                let rp = rhs.percent.unwrap_or(-1.0);
                lp.total_cmp(&rp).then_with(|| {
                    let lr = lhs.reset_at.unwrap_or(i64::MAX);
                    let rr = rhs.reset_at.unwrap_or(i64::MAX);
                    rr.cmp(&lr)
                })
            })
            .unwrap_or_default()
    };

    ProviderUsage {
        primary: pick_worst(&primary_windows),
        weekly: pick_worst(&weekly_windows),
        scoped_limits,
        fetched_at: Some(fetched_at),
        ..ProviderUsage::default()
    }
}

/// Codex's spend-control limit. Three places may carry it; take the first
/// usable one in this order: response root, inside `rate_limit`, inside
/// `spend_control`.
///
/// The unit is **credits**, not money — OpenAI's spend controls are counted in
/// credits, so the figure is tagged `credits` and rendered without a symbol.
pub fn codex_extra_usage(json: &Value) -> Option<ExtraUsage> {
    let object = [
        &json["individual_limit"],
        &json["rate_limit"]["individual_limit"],
        &json["spend_control"]["individual_limit"],
    ]
    .into_iter()
    .find(|value| value.is_object())?;
    let limit = flexible_f64(&object["limit"]).filter(|limit| *limit > 0.0)?;
    // With `used` absent, derive it from the remaining percentage: the API has
    // reported either shape, and one missing field should not hide the block.
    let remaining = flexible_f64(&object["remaining_percent"])
        .or_else(|| flexible_f64(&object["remainingPercent"]));
    let used = flexible_f64(&object["used"])
        .or_else(|| {
            remaining.map(|value| limit * value.clamp(0.0, 100.0).mul_add(-1.0, 100.0) / 100.0)
        })
        .unwrap_or(0.0);
    let percent = remaining.map_or(used / limit * 100.0, |value| 100.0 - value);
    Some(ExtraUsage {
        used,
        limit,
        percent: percent.clamp(0.0, 100.0),
        unit: Unit::Credits,
    })
}

/// Credit balance. Returned only when the API says the account has a credit
/// pool. `balance` has been observed as the string `"0"` as well as a number,
/// so both are accepted.
pub fn codex_credit_balance(json: &Value) -> Option<f64> {
    let credits = json["credits"].as_object()?;
    if credits.get("has_credits").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    flexible_f64(credits.get("balance")?)
}

/// The same field has appeared as both a number and a string. Anything else
/// yields `None` rather than 0 — a fabricated zero reads as "limit exhausted".
fn flexible_f64(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))
}

/// `additional_rate_limits` are limits that sit alongside primary/secondary but
/// apply to a single model (e.g. Codex Spark). They land in the same
/// `scoped_limits` field as Claude's: both answer the same question — the
/// account total is fine, but how much of *this model's* share is left.
///
/// One entry may carry both a 5-hour and a weekly window; each gets its own
/// row, and an entry with only one window yields only one.
pub fn codex_scoped_limits(json: &Value, now: i64) -> Vec<ScopedLimit> {
    let mut result: Vec<ScopedLimit> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for entry in json["additional_rate_limits"]
        .as_array()
        .unwrap_or(&Vec::new())
    {
        let name = entry
            .get("limit_name")
            .or_else(|| entry.get("metered_feature"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        if name.is_empty() {
            continue;
        }
        let (primary, weekly) = codex_windows(&entry["rate_limit"], now);
        for (suffix, window) in [("", primary), (" weekly", weekly)] {
            if window.percent.is_none() {
                continue;
            }
            let title = format!("{name}{suffix}");
            if seen.contains(&title.to_ascii_lowercase()) {
                continue;
            }
            seen.push(title.to_ascii_lowercase());
            result.push(ScopedLimit {
                id: title.clone(),
                title,
                window,
            });
        }
    }
    result
}

/// Anthropic's OAuth usage payload, everything the panel shows in one place.
pub fn claude_usage(json: &Value, fetched_at: i64, now: i64) -> ProviderUsage {
    ProviderUsage {
        primary: iso_window(&json["five_hour"], now),
        weekly: iso_window(&json["seven_day"], now),
        scoped_limits: claude_scoped_limits(json, now),
        extra_usage: claude_extra_usage(&json["extra_usage"]),
        credit_balance: None,
        error: None,
        fetched_at: Some(fetched_at),
        is_cached: false,
    }
}

/// `extra_usage` amounts are minor units; `decimal_places` says how far to
/// shift. A disabled pool yields `None` — a "$0 / $0" row is just noise.
pub fn claude_extra_usage(value: &Value) -> Option<ExtraUsage> {
    let object = value.as_object()?;
    if object.get("is_enabled").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let used = object.get("used_credits").and_then(Value::as_f64)?;
    let limit = object.get("monthly_limit").and_then(Value::as_f64)?;
    if limit <= 0.0 {
        return None;
    }
    let places = object
        .get("decimal_places")
        .and_then(number_as_i64)
        .unwrap_or(2)
        .clamp(0, 6);
    let scale = 10f64.powi(places as i32);
    let percent = object
        .get("utilization")
        .and_then(Value::as_f64)
        .unwrap_or(used / limit * 100.0);
    Some(ExtraUsage {
        used: used / scale,
        limit: limit / scale,
        percent: percent.clamp(0.0, 100.0),
        unit: object
            .get("currency")
            .and_then(Value::as_str)
            .map_or(Unit::USD, Unit::parse),
    })
}

/// Model-scoped weekly limits. Newer payloads carry them in the `limits` array
/// (entries with a `scope.model`); older accounts still report the flat
/// `seven_day_opus` / `seven_day_sonnet` keys, so both are read.
///
/// `is_active` is deliberately not a filter: limits observed to be enforced
/// still report false, and treating it as a switch hides them entirely.
pub fn claude_scoped_limits(json: &Value, now: i64) -> Vec<ScopedLimit> {
    let mut result: Vec<ScopedLimit> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for entry in json["limits"].as_array().unwrap_or(&Vec::new()) {
        let group = entry
            .get("group")
            .or_else(|| entry.get("kind"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !group.contains("weekly") {
            continue;
        }
        let Some(model) = entry.pointer("/scope/model").and_then(Value::as_object) else {
            continue;
        };
        let id = model.get("id").and_then(Value::as_str).unwrap_or_default();
        let title = model
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or(id);
        if title.is_empty() || seen.contains(&title.to_ascii_lowercase()) {
            continue;
        }
        let window = UsageWindow {
            percent: entry.get("percent").and_then(Value::as_f64),
            reset_at: entry
                .get("resets_at")
                .and_then(Value::as_str)
                .and_then(parse_iso_epoch),
        }
        .discard_if_expired(now);
        if window.percent.is_none() {
            continue;
        }
        seen.push(title.to_ascii_lowercase());
        result.push(ScopedLimit {
            id: if id.is_empty() { title } else { id }.to_string(),
            title: title.to_string(),
            window,
        });
    }
    for (key, title) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
        if seen.contains(&title.to_ascii_lowercase()) {
            continue;
        }
        let window = iso_window(&json[key], now);
        if window.percent.is_none() {
            continue;
        }
        seen.push(title.to_ascii_lowercase());
        result.push(ScopedLimit {
            id: key.to_string(),
            title: title.to_string(),
            window,
        });
    }
    result
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

/// `claude-code/<version>`, resolved once. The native installer symlinks the
/// executable to `.../versions/<version>`, so following the link is enough;
/// other install layouts fall back to a constant rather than spawning
/// `claude --version` for every request.
pub fn claude_code_user_agent() -> &'static str {
    static AGENT: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    AGENT.get_or_init(|| {
        let version = ["~/.local/bin/claude", "/usr/local/bin/claude"]
            .into_iter()
            .find_map(|candidate| {
                let path = match candidate.strip_prefix("~/") {
                    Some(rest) => dirs::home_dir()?.join(rest),
                    None => PathBuf::from(candidate),
                };
                claude_version_in_path(&fs::canonicalize(path).ok()?)
            })
            .unwrap_or_else(|| FALLBACK_CLAUDE_CODE_VERSION.to_string());
        format!("claude-code/{version}")
    })
}

fn claude_version_in_path(path: &Path) -> Option<String> {
    path.components()
        .rev()
        .filter_map(|component| component.as_os_str().to_str())
        .find(|component| {
            let parts: Vec<&str> = component.split('.').collect();
            parts.len() >= 3
                && parts[..3]
                    .iter()
                    .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        })
        .map(str::to_string)
}

/// RFC 7231 allows `Retry-After` to be seconds or an HTTP-date; accept both.
/// An unparseable value yields `None` so the caller keeps its own backoff —
/// never treat it as 0 and retry immediately.
pub fn retry_after_seconds(value: Option<&str>, now: i64) -> Option<f64> {
    let raw = value?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(seconds) = raw.parse::<f64>() {
        return (seconds > 0.0).then_some(seconds);
    }
    let date = chrono::DateTime::parse_from_rfc2822(raw).ok()?;
    let delta = (date.timestamp() - now) as f64;
    (delta > 0.0).then_some(delta)
}

/// Wait exactly as long as the server asked. This used to be a hard-coded
/// 300 s while the observed header was `Retry-After: 414`, which combined with
/// the 120 s timer into a 360 s retry that always landed back inside the
/// window — and every failure pushed the window out again. 5 s of slack avoids
/// the boundary; the 1 h ceiling keeps one absurd value from starving refresh.
pub fn backoff_interval(retry_after: Option<f64>, rate_limited: bool) -> i64 {
    match retry_after {
        None => {
            if rate_limited {
                300
            } else {
                60
            }
        }
        Some(seconds) => (seconds + 5.0).clamp(60.0, 3600.0) as i64,
    }
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
        fetched_at: Some(fetched_at),
        is_cached: true,
        ..ProviderUsage::default()
    })
}

/// Retains the previous good windows when a fetch fails or a stale cache would
/// overwrite fresher in-memory data (port of UsageFetcher.keepLastGood).
pub fn keep_last_good(old: &ProviderUsage, new: ProviderUsage, now: i64) -> ProviderUsage {
    let mut current = new;
    // The statusline cache carries neither the extra-usage pool nor the scoped
    // limits; it landing must not erase what the last real fetch found. The
    // card is already flagged as cached, so the values are not passed off as
    // live — whereas the whole block vanishing reads as "the pool was closed".
    if current.is_cached {
        if current.extra_usage.is_none() {
            current.extra_usage = old.extra_usage;
        }
        if current.credit_balance.is_none() {
            current.credit_balance = old.credit_balance;
        }
        if current.scoped_limits.is_empty() {
            current.scoped_limits = old.scoped_limits.clone();
        }
    }
    current.primary = current.primary.discard_if_expired(now);
    current.weekly = current.weekly.discard_if_expired(now);
    let previous_primary = old.primary.discard_if_expired(now);
    let previous_weekly = old.weekly.discard_if_expired(now);
    let had_good_value = previous_primary.percent.is_some() || previous_weekly.percent.is_some();
    let retain = |error: Option<String>| ProviderUsage {
        primary: previous_primary,
        weekly: previous_weekly,
        scoped_limits: old.scoped_limits.clone(),
        extra_usage: old.extra_usage,
        credit_balance: old.credit_balance,
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
    stored_gemini: ProviderUsage,
    gemini_access_token: Option<(String, i64)>,
    gemini_project_id: Option<String>,
    last_timer: i64,
    next_allowed: i64,
    /// Longest `Retry-After` the servers asked for this round; read and
    /// cleared when the round's results land.
    pending_retry_after: Option<f64>,
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
    gemini_home: PathBuf,
    statusline_cache: PathBuf,
    quota_fetch_s: u64,
    store: super::store::QuotaStore,
    state: std::sync::Mutex<QuotaState>,
}

impl QuotaFetcher {
    pub fn new(
        claude_home: PathBuf,
        codex_home: PathBuf,
        gemini_home: PathBuf,
        statusline_cache: PathBuf,
        quota_fetch_s: u64,
        store: super::store::QuotaStore,
    ) -> Self {
        let now = epoch_now();
        let state = QuotaState {
            stored_claude: store.load("claude", now).unwrap_or_default(),
            stored_codex: store.load("codex", now).unwrap_or_default(),
            stored_gemini: store.load("gemini", now).unwrap_or_default(),
            ..QuotaState::default()
        };
        Self {
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(20))
                .build(),
            claude_home,
            codex_home,
            gemini_home,
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

    pub fn gemini(&self, now: i64) -> ProviderUsage {
        self.state().stored_gemini.discarding_expired(now)
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
        let gemini = self.fetch_gemini(now);
        let rate_limited = [&claude.error, &codex.error, &gemini.error]
            .into_iter()
            .flatten()
            .any(|error| error.contains("429"));
        self.store.save("claude", &claude);
        self.store.save("codex", &codex);
        self.store.save("gemini", &gemini);
        let mut state = self.state();
        state.next_allowed = now + backoff_interval(state.pending_retry_after.take(), rate_limited);
        state.stored_claude = keep_last_good(&state.stored_claude, claude, now);
        state.stored_codex = keep_last_good(&state.stored_codex, codex, now);
        state.stored_gemini = keep_last_good(&state.stored_gemini, gemini, now);
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
            // The usage endpoint is Claude Code's own; sending someone else's
            // User-Agent announces "this is not Claude Code" for no gain.
            .set("User-Agent", claude_code_user_agent())
            .call();
        let json: Value = match response {
            Ok(response) => match response.into_json() {
                Ok(json) => json,
                Err(_) => {
                    let error = "claude usage response parse failed";
                    return self.claude_fallback(error.to_string(), error, now);
                }
            },
            Err(ureq::Error::Status(code, response)) => {
                self.note_retry_after(retry_after_seconds(response.header("Retry-After"), now));
                let error = format!("claude usage HTTP {code}");
                return self.claude_fallback(error.clone(), &error, now);
            }
            Err(ureq::Error::Transport(_)) => {
                let error = "claude usage request failed";
                return self.claude_fallback(error.to_string(), error, now);
            }
        };
        claude_usage(&json, now, now)
    }

    /// Both providers can be limited in the same round; the longer wait wins so
    /// one provider's window is not trampled to accommodate the other.
    fn note_retry_after(&self, seconds: Option<f64>) {
        let Some(seconds) = seconds else { return };
        let mut state = self.state();
        state.pending_retry_after = Some(state.pending_retry_after.unwrap_or(0.0).max(seconds));
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
        if !json["rate_limit"].is_object() {
            return ProviderUsage::with_error("codex usage response parse failed");
        }
        codex_usage(&json, now, now)
    }

    fn resolve_gemini_token(
        &self,
        now: i64,
        force_refresh: bool,
    ) -> Result<Option<String>, String> {
        if !force_refresh {
            if let Some((token, expires_at)) = self.state().gemini_access_token.clone() {
                if expires_at - now > 60 {
                    return Ok(Some(token));
                }
            }
        }
        let Some(creds) = creds::gemini_credentials(&self.gemini_home)? else {
            return Ok(None);
        };
        if !force_refresh {
            if let Some(token) = creds.access_token_usable(now) {
                return Ok(Some(token.to_string()));
            }
        }
        let refresh_token = creds
            .refresh_token
            .ok_or_else(|| "gemini credentials expired; run gemini to log in".to_string())?;
        let (client_id, client_secret) = gemini_oauth_client_config()
            .ok_or_else(|| "gemini credentials expired; run gemini to log in".to_string())?;
        let response = self
            .agent
            .post("https://oauth2.googleapis.com/token")
            .send_form(&[
                ("client_id", client_id.as_str()),
                ("client_secret", client_secret.as_str()),
                ("refresh_token", refresh_token.as_str()),
                ("grant_type", "refresh_token"),
            ])
            .map_err(|_| "gemini credentials expired; auto-renew failed".to_string())?;
        let json: Value = response
            .into_json()
            .map_err(|_| "gemini credentials expired; auto-renew failed".to_string())?;
        let token = json["access_token"]
            .as_str()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| "gemini credentials expired; auto-renew failed".to_string())?
            .to_string();
        let expires_in = json["expires_in"].as_i64().unwrap_or(3600);
        self.state().gemini_access_token = Some((token.clone(), now + expires_in));
        Ok(Some(token))
    }

    fn resolve_gemini_project_id(&self, token: &str) -> Option<String> {
        for key in ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"] {
            if let Ok(value) = std::env::var(key) {
                if !value.is_empty() {
                    return Some(value);
                }
            }
        }
        if let Some(cached) = self.state().gemini_project_id.clone() {
            if !cached.is_empty() {
                return Some(cached);
            }
        }
        let url = format!("{GEMINI_CODE_ASSIST_BASE_URL}:loadCodeAssist");
        let body = serde_json::json!({
            "metadata": {
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            }
        });
        let response = self
            .agent
            .post(&url)
            .set("Authorization", &format!("Bearer {token}"))
            .set("Accept", "application/json")
            .send_json(body)
            .ok()?;
        let json: Value = response.into_json().ok()?;
        let project = json["cloudaicompanionProject"]
            .as_str()
            .filter(|value| !value.is_empty())
            .or_else(|| {
                json["cloudaicompanionProject"]["id"]
                    .as_str()
                    .filter(|value| !value.is_empty())
            })?
            .to_string();
        self.state().gemini_project_id = Some(project.clone());
        Some(project)
    }

    /// The `bool` is true while the cache is fresh enough to skip the API.
    fn cached_antigravity_gemini_usage(&self, now: i64) -> Option<(ProviderUsage, bool)> {
        let path = self
            .statusline_cache
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("antigravity.json");
        let metadata = fs::metadata(&path).ok()?;
        let modified = metadata
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs() as i64;
        if modified > now {
            return None;
        }
        let data = fs::read(&path).ok()?;
        let json: Value = serde_json::from_slice(&data).ok()?;
        let usage = antigravity_statusline_gemini_usage(&json, modified, now);
        if usage.primary.percent.is_none() && usage.weekly.percent.is_none() {
            return None;
        }
        let has_reset = usage.primary.reset_at.is_some() || usage.weekly.reset_at.is_some();
        let age = now - modified;
        if !has_reset && age > STATUSLINE_MAX_AGE_SECONDS {
            return None;
        }
        Some((usage, age <= ANTIGRAVITY_CACHE_FRESH_SECONDS))
    }

    fn fetch_gemini(&self, now: i64) -> ProviderUsage {
        let stale = match self.cached_antigravity_gemini_usage(now) {
            Some((usage, true)) => return usage,
            Some((usage, false)) => Some(usage),
            None => None,
        };
        let live = self.fetch_gemini_api(now);
        match stale {
            Some(usage) if live.primary.percent.is_none() && live.weekly.percent.is_none() => usage,
            _ => live,
        }
    }

    fn fetch_gemini_api(&self, now: i64) -> ProviderUsage {
        let mut token = match self.resolve_gemini_token(now, false) {
            Ok(Some(token)) => token,
            Ok(None) => return ProviderUsage::default(),
            Err(error) => return ProviderUsage::with_error(error),
        };
        let mut project_id = self.resolve_gemini_project_id(&token);
        let url = format!("{GEMINI_CODE_ASSIST_BASE_URL}:retrieveUserQuota");
        // The error is boxed while it is passed around: `ureq::Error` is 272+
        // bytes (clippy::result_large_err). It is unboxed again for the match.
        let call = |token: &str, project_id: Option<&str>| {
            let body = match project_id {
                Some(project) => serde_json::json!({ "project": project }),
                None => serde_json::json!({}),
            };
            self.agent
                .post(&url)
                .set("Authorization", &format!("Bearer {token}"))
                .set("Accept", "application/json")
                .send_json(body)
                .map_err(Box::new)
        };
        let mut response = call(&token, project_id.as_deref());
        if matches!(&response, Err(error) if matches!(**error, ureq::Error::Status(401, _))) {
            match self.resolve_gemini_token(now, true) {
                Ok(Some(refreshed)) => {
                    token = refreshed;
                    if project_id.is_none() {
                        project_id = self.resolve_gemini_project_id(&token);
                    }
                    response = call(&token, project_id.as_deref());
                }
                Ok(None) => return ProviderUsage::default(),
                Err(error) => return ProviderUsage::with_error(error),
            }
        }
        let json: Value = match response.map_err(|error| *error) {
            Ok(response) => match response.into_json() {
                Ok(json) => json,
                Err(_) => return ProviderUsage::with_error("gemini usage response parse failed"),
            },
            Err(ureq::Error::Status(401, _)) => {
                return ProviderUsage::with_error(
                    "gemini credentials expired; run gemini to log in",
                )
            }
            Err(ureq::Error::Status(code, response)) => {
                self.note_retry_after(retry_after_seconds(response.header("Retry-After"), now));
                return ProviderUsage::with_error(format!("gemini usage HTTP {code}"));
            }
            Err(ureq::Error::Transport(_)) => {
                return ProviderUsage::with_error("gemini usage request failed")
            }
        };
        gemini_usage(&json, now, now)
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

    /// Shape observed on the live endpoint (2026-08): extra-usage amounts are
    /// minor units, `decimal_places` says how far to shift. Rendering the raw
    /// `monthly_limit` would overstate the cap a hundredfold.
    #[test]
    fn extra_usage_amounts_are_scaled_to_major_units() {
        let extra = claude_extra_usage(&json!({
            "is_enabled": true,
            "monthly_limit": 10000,
            "used_credits": 1030.0,
            "utilization": 10.3,
            "currency": "USD",
            "decimal_places": 2
        }))
        .expect("extra usage");
        assert!((extra.limit - 100.0).abs() < 1e-9);
        assert!((extra.used - 10.30).abs() < 1e-9);
        assert!((extra.percent - 10.3).abs() < 1e-9);
        assert_eq!(extra.unit, Unit::USD);

        // No utilization reported: derive it. No currency: assume USD.
        let derived = claude_extra_usage(&json!({
            "is_enabled": true, "monthly_limit": 20000, "used_credits": 5000.0
        }))
        .expect("extra usage");
        assert!((derived.percent - 25.0).abs() < 1e-9);
        assert_eq!(derived.unit.code(), "USD");
    }

    /// A disabled or capless pool is not rendered: "$0 / $0" is only noise.
    #[test]
    fn extra_usage_absent_when_disabled_or_unlimited() {
        assert!(claude_extra_usage(&json!({
            "is_enabled": false, "monthly_limit": 10000, "used_credits": 0.0
        }))
        .is_none());
        assert!(claude_extra_usage(&json!({
            "is_enabled": true, "monthly_limit": 0, "used_credits": 0.0
        }))
        .is_none());
        assert!(claude_extra_usage(&json!(null)).is_none());
    }

    /// Scoped weekly limits come from the `limits` array on newer payloads and
    /// from the flat `seven_day_*` keys on older ones; the same model must not
    /// be listed twice when both are present.
    #[test]
    fn scoped_weekly_limits_read_both_shapes_and_deduplicate() {
        let now = parse_iso_epoch("2026-07-18T10:00:00Z").unwrap();
        let json = json!({
            "limits": [
                // Account-wide weekly limit: no scope, so not a model limit
                {"kind": "weekly_all", "group": "weekly", "percent": 39,
                 "resets_at": "2026-07-18T13:00:00Z", "scope": null, "is_active": true},
                // is_active reports false on limits observed to be enforced
                {"kind": "weekly_scoped", "group": "weekly", "percent": 61,
                 "resets_at": "2026-07-18T13:00:00Z", "is_active": false,
                 "scope": {"model": {"id": "claude-opus-5", "display_name": "Opus"}}}
            ],
            "seven_day_opus": {"utilization": 12, "resets_at": "2026-07-18T13:00:00Z"},
            "seven_day_sonnet": {"utilization": 7, "resets_at": "2026-07-18T13:00:00Z"}
        });
        let limits = claude_scoped_limits(&json, now);
        assert_eq!(
            limits
                .iter()
                .map(|limit| limit.title.as_str())
                .collect::<Vec<_>>(),
            ["Opus", "Sonnet"]
        );
        assert_eq!(limits[0].id, "claude-opus-5");
        assert_eq!(
            limits[0].window.percent,
            Some(61.0),
            "the limits array wins"
        );
        assert_eq!(limits[0].window.reset_minutes(now), Some(180));
        assert_eq!(limits[1].window.percent, Some(7.0));
        assert!(claude_scoped_limits(&json!({}), now).is_empty());
    }

    /// An expired scoped limit must not linger as if it were still in force.
    #[test]
    fn expired_scoped_limits_are_dropped() {
        let now = parse_iso_epoch("2026-07-18T10:00:00Z").unwrap();
        let json = json!({
            "seven_day_opus": {"utilization": 88, "resets_at": "2026-07-18T09:00:00Z"}
        });
        assert!(claude_scoped_limits(&json, now).is_empty());
    }

    /// The statusline cache knows nothing about the pool; it landing must not
    /// erase what the last real fetch found.
    #[test]
    fn cached_fallback_keeps_the_last_known_extra_usage() {
        let extra = ExtraUsage {
            used: 10.3,
            limit: 100.0,
            percent: 10.3,
            unit: Unit::USD,
        };
        let old = ProviderUsage {
            primary: UsageWindow {
                percent: Some(9.0),
                reset_at: Some(NOW + 600),
            },
            extra_usage: Some(extra),
            fetched_at: Some(NOW - 600),
            ..ProviderUsage::default()
        };
        let cached = ProviderUsage {
            primary: UsageWindow {
                percent: Some(6.0),
                reset_at: Some(NOW + 1800),
            },
            error: Some("claude usage HTTP 429".to_string()),
            fetched_at: Some(NOW),
            is_cached: true,
            ..ProviderUsage::default()
        };
        assert_eq!(keep_last_good(&old, cached, NOW).extra_usage, Some(extra));
    }

    /// Wait exactly as long as the server asked. Both header forms are legal,
    /// and an unparseable value must fall back rather than retry immediately.
    #[test]
    fn retry_after_drives_the_backoff() {
        assert_eq!(retry_after_seconds(Some("414"), NOW), Some(414.0));
        assert_eq!(retry_after_seconds(Some("  "), NOW), None);
        assert_eq!(retry_after_seconds(Some("soon"), NOW), None);
        assert_eq!(retry_after_seconds(Some("0"), NOW), None);
        assert_eq!(retry_after_seconds(None, NOW), None);
        assert_eq!(
            retry_after_seconds(Some("Wed, 21 Oct 2026 07:28:00 GMT"), 1_760_000_000),
            Some(32_567_680.0)
        );

        assert_eq!(backoff_interval(Some(414.0), true), 419);
        assert_eq!(
            backoff_interval(Some(1.0), true),
            60,
            "never below the floor"
        );
        assert_eq!(
            backoff_interval(Some(99_999.0), true),
            3600,
            "never starved"
        );
        assert_eq!(backoff_interval(None, true), 300);
        assert_eq!(backoff_interval(None, false), 60);
    }

    /// The native installer symlinks the executable to `.../versions/<v>`.
    #[test]
    fn claude_version_is_read_from_the_resolved_path() {
        assert_eq!(
            claude_version_in_path(Path::new(
                "/home/someone/.local/share/claude/versions/2.1.228"
            )),
            Some("2.1.228".to_string())
        );
        assert_eq!(
            claude_version_in_path(Path::new(
                "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            )),
            None,
            "other layouts fall back rather than invent a version"
        );
        assert!(claude_code_user_agent().starts_with("claude-code/"));
    }

    /// Shape observed on the live endpoint (2026-08): this account reports a
    /// single 604800-second `primary_window`, which by duration is the weekly
    /// window and must not be shown as the 5-hour one.
    #[test]
    fn codex_windows_are_classified_by_duration_not_field_name() {
        let json = json!({
            "rate_limit": {
                "primary_window": {
                    "used_percent": 88, "limit_window_seconds": 604800,
                    "reset_at": NOW + 3600
                },
                "secondary_window": null
            }
        });
        let usage = codex_usage(&json, NOW, NOW);
        assert_eq!(
            usage.primary.percent, None,
            "a 7-day window is not a 5h one"
        );
        assert_eq!(usage.weekly.percent, Some(88.0));
        assert_eq!(usage.weekly.reset_minutes(NOW), Some(60));
    }

    /// `additional_rate_limits` are model-scoped limits and land in the same
    /// field as Claude's scoped weekly limits; one entry's two windows each get
    /// their own row.
    #[test]
    fn codex_additional_rate_limits_become_scoped_limits() {
        let json = json!({
            "additional_rate_limits": [
                {
                    "limit_name": "Codex Spark",
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 12, "limit_window_seconds": 18000,
                            "reset_at": NOW + 1800
                        },
                        "secondary_window": {
                            "used_percent": 45, "limit_window_seconds": 604800,
                            "reset_at": NOW + 7200
                        }
                    }
                },
                // An unnamed entry cannot be referred to on screen
                {"rate_limit": {"primary_window": {"used_percent": 5}}}
            ]
        });
        let limits = codex_scoped_limits(&json, NOW);
        assert_eq!(
            limits
                .iter()
                .map(|limit| limit.title.as_str())
                .collect::<Vec<_>>(),
            ["Codex Spark", "Codex Spark weekly"]
        );
        assert_eq!(limits[0].window.percent, Some(12.0));
        assert_eq!(limits[0].window.reset_minutes(NOW), Some(30));
        assert_eq!(limits[1].window.percent, Some(45.0));
        assert!(codex_scoped_limits(&json!({}), NOW).is_empty());
    }

    /// Codex's spend-control limit is counted in **credits**, not money. Three
    /// places may carry it; take the first usable one in root → rate_limit →
    /// spend_control order.
    #[test]
    fn codex_spend_control_limit_is_read_in_precedence_order_and_counted_in_credits() {
        let root = codex_extra_usage(&json!({
            "individual_limit": {"limit": 1000, "used": 250},
            "rate_limit": {"individual_limit": {"limit": 9999, "used": 1}}
        }))
        .expect("root limit");
        assert_eq!(root.limit, 1000.0);
        assert_eq!(root.used, 250.0);
        assert_eq!(root.percent, 25.0);
        assert_eq!(root.unit, Unit::Credits, "credits must not wear a $");

        let nested = codex_extra_usage(&json!({
            "rate_limit": {"individual_limit": {"limit": 500, "used": 100}},
            "spend_control": {"individual_limit": {"limit": 9999, "used": 1}}
        }))
        .expect("rate_limit limit");
        assert_eq!(nested.limit, 500.0);

        // With `used` absent, derive it from the remaining percentage
        let derived = codex_extra_usage(&json!({
            "spend_control": {"individual_limit": {"limit": 200, "remaining_percent": 90}}
        }))
        .expect("spend_control limit");
        assert!((derived.used - 20.0).abs() < 1e-9);
        assert!((derived.percent - 10.0).abs() < 1e-9);

        // Exactly what this machine's account reports: no limit to invent
        assert!(codex_extra_usage(&json!({
            "spend_control": {"reached": false, "individual_limit": null}
        }))
        .is_none());
        assert!(codex_extra_usage(&json!({"individual_limit": {"limit": 0}})).is_none());
        assert!(codex_extra_usage(&json!({})).is_none());
    }

    /// `credits.balance` has been observed as the string `"0"` and as a number.
    /// Shown only when `has_credits` is true — a "balance 0" row on every Plus
    /// account is noise.
    #[test]
    fn codex_credit_balance_only_appears_for_accounts_that_have_credits() {
        assert_eq!(
            codex_credit_balance(&json!({"credits": {"has_credits": true, "balance": "1250.5"}})),
            Some(1250.5)
        );
        assert_eq!(
            codex_credit_balance(&json!({"credits": {"has_credits": true, "balance": 42}})),
            Some(42.0)
        );
        // This machine's account: has_credits=false, so no row at all
        assert_eq!(
            codex_credit_balance(&json!({
                "credits": {"has_credits": false, "unlimited": false, "balance": "0"}
            })),
            None
        );
        assert_eq!(codex_credit_balance(&json!({})), None);
        // Unparseable means unknown, never 0 — a fabricated zero reads as
        // "the pool is exhausted".
        assert_eq!(
            codex_credit_balance(&json!({"credits": {"has_credits": true, "balance": "?"}})),
            None
        );
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
            fetched_at: Some(NOW - 120),
            ..ProviderUsage::default()
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
            ..ProviderUsage::default()
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
            ..ProviderUsage::default()
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
            ..ProviderUsage::default()
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
            PathBuf::new(),
            120,
            super::super::store::QuotaStore::new(PathBuf::new()),
        );
        assert!(fetcher.due(false));
        fetcher.state().fetching = true;

        assert!(!fetcher.due(false));
        assert!(!fetcher.due(true));
    }

    #[test]
    fn extracts_js_const_declaration_after_earlier_references() {
        let text = r#"x={clientId:OAUTH_CLIENT_ID};var a="decoy";var OAUTH_CLIENT_ID = "the-id";
            var OAUTH_CLIENT_SECRET='the-secret';if(OAUTH_CLIENT_ID=="x"){}"#;
        assert_eq!(
            extract_js_string_const(text, "OAUTH_CLIENT_ID").as_deref(),
            Some("the-id")
        );
        assert_eq!(
            extract_js_string_const(text, "OAUTH_CLIENT_SECRET").as_deref(),
            Some("the-secret")
        );
        assert_eq!(
            extract_js_string_const("OAUTH_CLIENT_ID == \"x\"", "OAUTH_CLIENT_ID"),
            None
        );
    }

    #[test]
    fn finds_gemini_bundle_through_path_symlink_and_nvm() {
        let root = std::env::temp_dir().join(format!("elink-gemini-bundle-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let home = root.join("home");
        let nvm =
            home.join(".nvm/versions/node/v22.1.0/lib/node_modules/@google/gemini-cli/bundle");
        fs::create_dir_all(&nvm).unwrap();
        // A formula-style install reached only through a `gemini` symlink on PATH.
        let cellar =
            root.join("Cellar/gemini-cli/1.0/libexec/lib/node_modules/@google/gemini-cli/bundle");
        fs::create_dir_all(&cellar).unwrap();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink(cellar.join("gemini.js"), bin.join("gemini")).unwrap();
        fs::write(cellar.join("gemini.js"), "").unwrap();

        let dirs = gemini_cli_bundle_dirs(Some(&home), Some(bin.as_os_str()));
        let canon = |p: &Path| fs::canonicalize(p).unwrap();
        let dirs: Vec<PathBuf> = dirs.iter().map(|d| canon(d)).collect();
        assert!(dirs.contains(&canon(&cellar)), "{dirs:?}");
        assert!(dirs.contains(&canon(&nvm)), "{dirs:?}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn stale_antigravity_cache_is_only_a_fallback() {
        let root = std::env::temp_dir().join(format!("elink-agy-cache-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("antigravity.json");
        let body = json!({"quota": {"gemini-weekly": {
            "remaining_fraction": 0.5, "reset_time": "2099-01-01T00:00:00Z"
        }}});
        fs::write(&path, body.to_string()).unwrap();
        let modified = fs::metadata(&path)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let fetcher = QuotaFetcher::new(
            PathBuf::new(),
            PathBuf::new(),
            PathBuf::new(),
            root.join("last.json"),
            120,
            super::super::store::QuotaStore::new(PathBuf::new()),
        );

        let (usage, fresh) = fetcher
            .cached_antigravity_gemini_usage(modified + 60)
            .unwrap();
        assert!(fresh);
        assert_eq!(usage.weekly.percent, Some(50.0));
        // A future reset time no longer keeps an old file "fresh".
        let (usage, fresh) = fetcher
            .cached_antigravity_gemini_usage(modified + ANTIGRAVITY_CACHE_FRESH_SECONDS + 1)
            .unwrap();
        assert!(!fresh);
        assert_eq!(usage.weekly.percent, Some(50.0));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn parses_gemini_five_hour_and_weekly_buckets_and_scoped_limits() {
        // NOW = 1_783_933_200 = 2026-07-13T09:00:00Z
        let json = json!({
            "buckets": [
                {
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.6,
                    "resetTime": "2026-07-13T12:00:00Z",
                    "window": "5h"
                },
                {
                    "modelId": "gemini-2.5-flash",
                    "remainingFraction": 0.85,
                    "resetTime": "2026-07-13T13:00:00Z",
                    "window": "5h"
                },
                {
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.3,
                    "resetTime": "2026-07-18T09:00:00Z",
                    "window": "weekly"
                }
            ]
        });
        let usage = gemini_usage(&json, NOW, NOW);
        assert!((usage.primary.percent.unwrap() - 40.0).abs() < 1e-6);
        assert_eq!(usage.primary.reset_minutes(NOW), Some(180));
        assert!((usage.weekly.percent.unwrap() - 70.0).abs() < 1e-6);
        assert_eq!(usage.weekly.reset_minutes(NOW), Some(5 * 24 * 60));
        assert_eq!(usage.scoped_limits.len(), 3);
        assert_eq!(usage.scoped_limits[0].title, "Pro");
        assert_eq!(usage.scoped_limits[1].title, "Flash");
        assert_eq!(usage.scoped_limits[2].title, "Pro weekly");
    }

    #[test]
    fn gemini_usage_keeps_missing_weekly_window_as_none() {
        let json = json!({
            "buckets": [
                {
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.75,
                    "resetTime": "2026-07-13T14:00:00Z"
                }
            ]
        });
        let usage = gemini_usage(&json, NOW, NOW);
        assert!((usage.primary.percent.unwrap() - 25.0).abs() < 1e-6);
        assert_eq!(usage.weekly.percent, None);
        assert!(usage.scoped_limits.is_empty());
    }
}
