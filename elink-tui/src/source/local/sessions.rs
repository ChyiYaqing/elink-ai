use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Local};
use serde_json::Value;

use crate::model::ModelUsage;
use crate::source::local::history::DayTotals;
use crate::source::local::quota::parse_iso_epoch;

#[cfg(test)]
thread_local! {
    static DIRECTORY_READS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// One-shot scan of every session file modified after `cutoff_epoch`,
/// bucketed per local day — the startup history backfill (lightweight
/// equivalent of StatusService.computeDailyTotals). Slow on large session
/// trees; run it off the poll thread.
pub fn full_daily_totals(
    claude_home: &Path,
    codex_home: &Path,
    cutoff_epoch: i64,
) -> (DayTotals, DayTotals) {
    let mut messages = ClaudeMessages::new();
    for (path, mtime, _) in jsonl_files(&claude_home.join("projects")) {
        if epoch(mtime) < cutoff_epoch {
            continue;
        }
        let text = fs::read_to_string(&path).unwrap_or_default();
        parse_claude_lines(&text, &mut messages);
    }
    let claude = claude_daily_totals(&messages);

    let mut codex = DayTotals::new();
    for (path, mtime, _) in jsonl_files(&codex_home.join("sessions")) {
        if epoch(mtime) < cutoff_epoch {
            continue;
        }
        let text = fs::read_to_string(&path).unwrap_or_default();
        for (timestamp, model, tokens) in parse_codex_lines(&text).events {
            *codex
                .entry(day_key(timestamp))
                .or_default()
                .entry(model)
                .or_insert(0) += tokens;
        }
    }
    (claude, codex)
}

/// One deduplicated Claude message. Streaming updates and session resumes
/// repeat a message id across lines and files; the largest token count wins.
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeMessage {
    pub timestamp: i64,
    pub model: String,
    pub tokens: u64,
}

pub type ClaudeMessages = HashMap<String, ClaudeMessage>;

/// (epoch seconds, model, token delta) for one Codex token_count event.
pub type CodexEvent = (i64, String, u64);

#[derive(Debug, Default, Clone)]
pub struct CodexParsed {
    pub events: Vec<CodexEvent>,
    /// Latest `payload.rate_limits` in the file with its raw timestamp string.
    pub rate_limits: Option<(String, Value)>,
}

struct CacheEntry<T> {
    mtime: SystemTime,
    len: u64,
    value: T,
}

#[derive(Clone, Copy)]
struct FileStamp {
    mtime: SystemTime,
    len: u64,
}

const HISTORICAL_FILE_REFRESH_BATCH: usize = 64;
const FULL_INDEX_REFRESH_INTERVAL: Duration = Duration::from_secs(15);

/// In-memory directory index used by the two-second status poll. The first
/// poll discovers the tree; later polls only enumerate directories whose
/// mtime changed, stat today's files, and check a bounded batch of older files
/// for resumed sessions. A 15-second full refresh bounds discovery latency on
/// filesystems whose directory mtimes are too coarse to report every change.
struct FileIndex {
    root: PathBuf,
    directories: HashMap<PathBuf, Option<SystemTime>>,
    files: HashMap<PathBuf, FileStamp>,
    file_order: Vec<PathBuf>,
    historical_cursor: usize,
    last_full_refresh: Option<Instant>,
}

impl FileIndex {
    fn new(root: PathBuf) -> Self {
        Self {
            root,
            directories: HashMap::new(),
            files: HashMap::new(),
            file_order: Vec::new(),
            historical_cursor: 0,
            last_full_refresh: None,
        }
    }

    fn files(&mut self, start_of_day: i64) -> (Vec<(PathBuf, SystemTime, u64)>, bool) {
        let full_refresh_due = self
            .last_full_refresh
            .is_none_or(|at| at.elapsed() >= FULL_INDEX_REFRESH_INTERVAL);
        let rebuilt = self.directories.is_empty() || full_refresh_due;
        if rebuilt {
            self.rebuild();
        } else {
            self.refresh_directories();
            self.refresh_files(start_of_day);
        }
        (
            self.files
                .iter()
                .map(|(path, stamp)| (path.clone(), stamp.mtime, stamp.len))
                .collect(),
            rebuilt,
        )
    }

    fn rebuild(&mut self) {
        self.directories.clear();
        self.files.clear();
        self.file_order.clear();
        self.historical_cursor = 0;
        self.directories
            .insert(self.root.clone(), directory_mtime(&self.root));
        self.scan_directory(self.root.clone());
        self.last_full_refresh = Some(Instant::now());
    }

    fn refresh_directories(&mut self) {
        let known: Vec<(PathBuf, Option<SystemTime>)> = self
            .directories
            .iter()
            .map(|(path, mtime)| (path.clone(), *mtime))
            .collect();
        for (path, previous) in known {
            if !self.directories.contains_key(&path) {
                continue;
            }
            let current = directory_mtime(&path);
            if current == previous {
                continue;
            }
            if current.is_some() {
                self.scan_directory(path);
            } else if path == self.root {
                self.directories.clear();
                self.directories.insert(self.root.clone(), None);
                self.files.clear();
                self.file_order.clear();
                self.historical_cursor = 0;
            } else {
                self.remove_tree(&path);
            }
        }
    }

    fn scan_directory(&mut self, directory: PathBuf) {
        record_directory_read();
        let Ok(entries) = fs::read_dir(&directory) else {
            self.directories
                .insert(directory.clone(), directory_mtime(&directory));
            return;
        };
        let mut seen = HashSet::new();
        let mut descend = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with('.'))
            {
                continue;
            }
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                seen.insert(path.clone());
                let current = entry
                    .metadata()
                    .ok()
                    .and_then(|value| value.modified().ok());
                let changed = self.directories.get(&path) != Some(&current);
                if changed {
                    self.directories.insert(path.clone(), current);
                    descend.push(path);
                }
            } else if path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
            {
                let Ok(metadata) = entry.metadata() else {
                    continue;
                };
                let Ok(mtime) = metadata.modified() else {
                    continue;
                };
                seen.insert(path.clone());
                self.insert_file(path, mtime, metadata.len());
            }
        }

        let removed_directories: Vec<PathBuf> = self
            .directories
            .keys()
            .filter(|path| path.as_path() != directory && path.parent() == Some(&directory))
            .filter(|path| !seen.contains(*path))
            .cloned()
            .collect();
        for path in removed_directories {
            self.remove_tree(&path);
        }
        let before = self.files.len();
        self.files
            .retain(|path, _| path.parent() != Some(directory.as_path()) || seen.contains(path));
        if self.files.len() != before {
            self.compact_file_order();
        }
        self.directories
            .insert(directory.clone(), directory_mtime(&directory));
        for child in descend {
            self.scan_directory(child);
        }
    }

    fn insert_file(&mut self, path: PathBuf, mtime: SystemTime, len: u64) {
        if !self.files.contains_key(&path) {
            self.file_order.push(path.clone());
        }
        self.files.insert(path, FileStamp { mtime, len });
    }

    fn refresh_files(&mut self, start_of_day: i64) {
        let mut paths: Vec<PathBuf> = self
            .files
            .iter()
            .filter(|(_, stamp)| epoch(stamp.mtime) >= start_of_day)
            .map(|(path, _)| path.clone())
            .collect();
        if let Some((latest, _)) = self.files.iter().max_by_key(|(_, stamp)| stamp.mtime) {
            if !paths.contains(latest) {
                paths.push(latest.clone());
            }
        }
        for path in paths {
            self.refresh_file(&path);
        }

        let order_len = self.file_order.len();
        let mut checked = 0;
        while checked < order_len && checked < HISTORICAL_FILE_REFRESH_BATCH {
            let index = self.historical_cursor % order_len;
            self.historical_cursor = (self.historical_cursor + 1) % order_len;
            let path = self.file_order[index].clone();
            if self
                .files
                .get(&path)
                .is_some_and(|stamp| epoch(stamp.mtime) < start_of_day)
            {
                self.refresh_file(&path);
            }
            checked += 1;
        }
        if self.file_order.len() != self.files.len() {
            self.compact_file_order();
        }
    }

    fn refresh_file(&mut self, path: &Path) {
        let Ok(metadata) = fs::metadata(path) else {
            self.files.remove(path);
            return;
        };
        let Ok(mtime) = metadata.modified() else {
            return;
        };
        if let Some(stamp) = self.files.get_mut(path) {
            stamp.mtime = mtime;
            stamp.len = metadata.len();
        }
    }

    fn remove_tree(&mut self, directory: &Path) {
        self.directories
            .retain(|path, _| !path.starts_with(directory));
        self.files.retain(|path, _| !path.starts_with(directory));
        self.compact_file_order();
    }

    fn compact_file_order(&mut self) {
        self.file_order.retain(|path| self.files.contains_key(path));
        if self.file_order.is_empty() {
            self.historical_cursor = 0;
        } else {
            self.historical_cursor %= self.file_order.len();
        }
    }
}

pub struct ProviderScan {
    pub state: &'static str,
    pub models: Vec<ModelUsage>,
    pub tokens_today: u64,
}

pub struct ScanOutcome {
    pub claude: ProviderScan,
    pub codex: ProviderScan,
    /// Log-derived Codex quota fallback: (epoch of observation, rate_limits).
    pub codex_rate_limits: Option<(i64, Value)>,
}

pub struct SessionScanner {
    claude_files: FileIndex,
    codex_files: FileIndex,
    claude_cache: HashMap<PathBuf, CacheEntry<ClaudeMessages>>,
    codex_cache: HashMap<PathBuf, CacheEntry<CodexParsed>>,
}

impl SessionScanner {
    pub fn new(claude_home: &Path, codex_home: &Path) -> Self {
        Self {
            claude_files: FileIndex::new(claude_home.join("projects")),
            codex_files: FileIndex::new(codex_home.join("sessions")),
            claude_cache: HashMap::new(),
            codex_cache: HashMap::new(),
        }
    }

    pub fn scan(&mut self) -> ScanOutcome {
        let now = Local::now();
        let today = now.format("%Y-%m-%d").to_string();
        let start_of_day = now
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .and_then(|midnight| midnight.and_local_timezone(Local).earliest())
            .map(|midnight| midnight.timestamp())
            .unwrap_or(0);

        let (claude_files, claude_rebuilt) = self.claude_files.files(start_of_day);
        if claude_rebuilt {
            self.claude_cache.clear();
        }
        let claude_state = activity_state(latest_mtime(&claude_files));
        let today_files: Vec<&(PathBuf, SystemTime, u64)> = claude_files
            .iter()
            .filter(|(_, mtime, _)| epoch(*mtime) >= start_of_day)
            .collect();
        let mut messages = ClaudeMessages::new();
        for (path, mtime, len) in &today_files {
            let parsed = cached_parse(&mut self.claude_cache, path, *mtime, *len, |text| {
                let mut value = ClaudeMessages::new();
                parse_claude_lines(text, &mut value);
                value
            });
            for (id, message) in parsed {
                let existing = messages.get(&id).map(|value| value.tokens);
                if existing.is_none_or(|tokens| message.tokens > tokens) {
                    messages.insert(id, message);
                }
            }
        }
        prune(&mut self.claude_cache, &today_files);
        let claude_totals = claude_daily_totals(&messages)
            .remove(&today)
            .unwrap_or_default();

        let (codex_files, codex_rebuilt) = self.codex_files.files(start_of_day);
        if codex_rebuilt {
            self.codex_cache.clear();
        }
        let codex_state = activity_state(latest_mtime(&codex_files));
        let today_files: Vec<&(PathBuf, SystemTime, u64)> = codex_files
            .iter()
            .filter(|(_, mtime, _)| epoch(*mtime) >= start_of_day)
            .collect();
        let mut codex_totals: HashMap<String, u64> = HashMap::new();
        let mut latest_limits: Option<(String, Value)> = None;
        for (path, mtime, len) in &today_files {
            let parsed = cached_parse(&mut self.codex_cache, path, *mtime, *len, parse_codex_lines);
            for (timestamp, model, tokens) in &parsed.events {
                if day_key(*timestamp) == today {
                    *codex_totals.entry(model.clone()).or_insert(0) += tokens;
                }
            }
            if let Some((timestamp, limits)) = parsed.rate_limits {
                let newer = latest_limits
                    .as_ref()
                    .is_none_or(|(latest, _)| timestamp.as_str() >= latest.as_str());
                if newer {
                    latest_limits = Some((timestamp, limits));
                }
            }
        }
        prune(&mut self.codex_cache, &today_files);
        let codex_rate_limits = latest_limits
            .and_then(|(timestamp, limits)| Some((parse_iso_epoch(&timestamp)?, limits)));

        ScanOutcome {
            claude: provider_scan(claude_state, claude_totals),
            codex: provider_scan(codex_state, codex_totals),
            codex_rate_limits,
        }
    }
}

fn provider_scan(state: &'static str, totals: HashMap<String, u64>) -> ProviderScan {
    let models = sorted_models(totals);
    let tokens_today = models.iter().map(|value| value.tokens).sum();
    ProviderScan {
        state,
        models,
        tokens_today,
    }
}

fn cached_parse<T: Clone>(
    cache: &mut HashMap<PathBuf, CacheEntry<T>>,
    path: &Path,
    mtime: SystemTime,
    len: u64,
    parse: impl Fn(&str) -> T,
) -> T {
    if let Some(entry) = cache.get(path) {
        if entry.mtime == mtime && entry.len == len {
            return entry.value.clone();
        }
    }
    let text = fs::read_to_string(path).unwrap_or_default();
    let value = parse(&text);
    cache.insert(
        path.to_path_buf(),
        CacheEntry {
            mtime,
            len,
            value: value.clone(),
        },
    );
    value
}

fn prune<T>(cache: &mut HashMap<PathBuf, CacheEntry<T>>, keep: &[&(PathBuf, SystemTime, u64)]) {
    let keep: std::collections::HashSet<&PathBuf> = keep.iter().map(|(path, _, _)| path).collect();
    cache.retain(|path, _| keep.contains(path));
}

/// Sums the four usage token fields per line, dedupes by `message.id` (falling
/// back to `uuid`, then the raw line) keeping the max, and records the raw
/// timestamp for later day bucketing.
pub fn parse_claude_lines(text: &str, messages: &mut ClaudeMessages) {
    for line in text.lines() {
        if !line.contains("\"usage\"") {
            continue;
        }
        let Ok(object) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(timestamp) = object
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_iso_epoch)
        else {
            continue;
        };
        let Some(message) = object.get("message").filter(|value| value.is_object()) else {
            continue;
        };
        let Some(usage) = message.get("usage").filter(|value| value.is_object()) else {
            continue;
        };
        let tokens: u64 = [
            "input_tokens",
            "output_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
        ]
        .iter()
        .map(|key| token_count(usage.get(*key)))
        .sum();
        if tokens == 0 {
            continue;
        }
        let id = message
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| object.get("uuid").and_then(Value::as_str))
            .unwrap_or(line)
            .to_string();
        let existing = messages.get(&id).map(|value| value.tokens);
        if existing.is_none_or(|value| tokens > value) {
            messages.insert(
                id,
                ClaudeMessage {
                    timestamp,
                    model: normalized_model(message.get("model")),
                    tokens,
                },
            );
        }
    }
}

pub fn claude_daily_totals(messages: &ClaudeMessages) -> HashMap<String, HashMap<String, u64>> {
    let mut totals: HashMap<String, HashMap<String, u64>> = HashMap::new();
    for message in messages.values() {
        *totals
            .entry(day_key(message.timestamp))
            .or_default()
            .entry(message.model.clone())
            .or_insert(0) += message.tokens;
    }
    totals
}

/// Port of StatusService.codexUsageEvents (usageParserVersion 2): token deltas
/// prefer `last_token_usage.total_tokens`, an unchanged cumulative total means
/// 0, otherwise the cumulative diff (or the cumulative itself on the first
/// event). Subagent files declare the model after early token_count lines, so
/// events before any declaration attach to the file's first declared model and
/// only a fully model-less file falls back to "unknown". Also captures the
/// latest `payload.rate_limits` for the log-derived quota fallback.
pub fn parse_codex_lines(text: &str) -> CodexParsed {
    let mut events: Vec<(i64, Option<String>, u64)> = Vec::new();
    let mut model: Option<String> = None;
    let mut first_model: Option<String> = None;
    let mut previous_total: Option<i64> = None;
    let mut rate_limits: Option<(String, Value)> = None;
    for line in text.lines() {
        let Ok(object) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(payload) = object.get("payload").filter(|value| value.is_object()) else {
            continue;
        };
        if let Some(value) = payload.get("model").and_then(Value::as_str) {
            if !value.is_empty() {
                model = Some(value.to_string());
                if first_model.is_none() {
                    first_model = Some(value.to_string());
                }
            }
        }
        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        let Some(info) = payload.get("info").filter(|value| value.is_object()) else {
            record_rate_limits(&object, payload, &mut rate_limits);
            continue;
        };
        record_rate_limits(&object, payload, &mut rate_limits);
        let Some(cumulative) = info
            .get("total_token_usage")
            .and_then(|value| value.get("total_tokens"))
            .and_then(Value::as_i64)
        else {
            continue;
        };
        let last = info
            .get("last_token_usage")
            .and_then(|value| value.get("total_tokens"))
            .and_then(Value::as_i64);
        let delta = match (previous_total, last) {
            (Some(previous), _) if cumulative == previous => 0,
            (_, Some(last)) => last,
            (Some(previous), None) => (cumulative - previous).max(0),
            (None, None) => cumulative,
        };
        previous_total = Some(cumulative);
        if delta <= 0 {
            continue;
        }
        let Some(timestamp) = object
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_iso_epoch)
        else {
            continue;
        };
        events.push((timestamp, model.clone(), delta as u64));
    }
    CodexParsed {
        events: events
            .into_iter()
            .map(|(timestamp, model, tokens)| {
                let model = model.or_else(|| first_model.clone());
                (timestamp, normalized_model_string(model), tokens)
            })
            .collect(),
        rate_limits,
    }
}

fn record_rate_limits(object: &Value, payload: &Value, latest: &mut Option<(String, Value)>) {
    let Some(limits) = payload.get("rate_limits").filter(|value| value.is_object()) else {
        return;
    };
    let timestamp = object
        .get("timestamp")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let newer = latest
        .as_ref()
        .is_none_or(|(previous, _)| timestamp.as_str() >= previous.as_str());
    if newer {
        *latest = Some((timestamp, limits.clone()));
    }
}

fn token_count(value: Option<&Value>) -> u64 {
    value
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_f64().map(|value| value as i64))
        })
        .map(|value| value.max(0) as u64)
        .unwrap_or(0)
}

fn normalized_model(value: Option<&Value>) -> String {
    normalized_model_string(value.and_then(Value::as_str).map(str::to_string))
}

fn normalized_model_string(value: Option<String>) -> String {
    match value {
        Some(model) => {
            let trimmed = model.trim();
            if trimmed.is_empty() {
                "unknown".to_string()
            } else {
                trimmed.to_string()
            }
        }
        None => "unknown".to_string(),
    }
}

pub fn day_key(timestamp: i64) -> String {
    DateTime::from_timestamp(timestamp, 0)
        .map(|value| value.with_timezone(&Local).format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

pub fn sorted_models(totals: HashMap<String, u64>) -> Vec<ModelUsage> {
    let mut models: Vec<ModelUsage> = totals
        .into_iter()
        .map(|(model, tokens)| ModelUsage { model, tokens })
        .collect();
    models.sort_by(|left, right| {
        right
            .tokens
            .cmp(&left.tokens)
            .then_with(|| left.model.cmp(&right.model))
    });
    models
}

/// Newest session file mtime: < 20 s means working, < 30 min idle, else offline.
fn activity_state(latest: Option<SystemTime>) -> &'static str {
    let Some(age) = latest.and_then(|value| value.elapsed().ok()) else {
        return "offline";
    };
    if age.as_secs() < 20 {
        "working"
    } else if age.as_secs() < 1800 {
        "idle"
    } else {
        "offline"
    }
}

fn epoch(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or(0)
}

fn latest_mtime(files: &[(PathBuf, SystemTime, u64)]) -> Option<SystemTime> {
    files.iter().map(|(_, mtime, _)| *mtime).max()
}

fn directory_mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path)
        .ok()
        .filter(|metadata| metadata.is_dir())
        .and_then(|metadata| metadata.modified().ok())
}

#[cfg(test)]
fn record_directory_read() {
    DIRECTORY_READS.with(|reads| reads.set(reads.get() + 1));
}

#[cfg(not(test))]
fn record_directory_read() {}

/// Recursively lists *.jsonl files with (mtime, len); a missing root is empty.
fn jsonl_files(root: &Path) -> Vec<(PathBuf, SystemTime, u64)> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        record_directory_read();
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with('.'))
            {
                continue;
            }
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                stack.push(path);
            } else if path
                .extension()
                .is_some_and(|extension| extension == "jsonl")
            {
                if let Ok(metadata) = entry.metadata() {
                    if let Ok(mtime) = metadata.modified() {
                        files.push((path, mtime, metadata.len()));
                    }
                }
            }
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn temp_homes() -> (PathBuf, PathBuf) {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-sessions-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let root = std::env::temp_dir().join(unique);
        let claude = root.join("claude");
        let codex = root.join("codex");
        fs::create_dir_all(claude.join("projects/project")).unwrap();
        fs::create_dir_all(codex.join("sessions")).unwrap();
        (claude, codex)
    }

    fn claude_line(id: &str, timestamp: &str, model: &str, tokens: [i64; 4]) -> String {
        serde_json::json!({
            "timestamp": timestamp,
            "uuid": format!("uuid-{id}"),
            "message": {
                "id": id,
                "model": model,
                "usage": {
                    "input_tokens": tokens[0],
                    "output_tokens": tokens[1],
                    "cache_creation_input_tokens": tokens[2],
                    "cache_read_input_tokens": tokens[3],
                }
            }
        })
        .to_string()
    }

    #[test]
    fn claude_parse_sums_dedupes_and_buckets() {
        let text = [
            claude_line(
                "msg-1",
                "2026-07-18T01:00:00Z",
                "claude-sonnet-5",
                [10, 5, 3, 2],
            ),
            // Streaming update of the same message with a larger total wins.
            claude_line(
                "msg-1",
                "2026-07-18T01:00:05Z",
                "claude-sonnet-5",
                [10, 25, 3, 2],
            ),
            // A smaller duplicate must not replace the larger total.
            claude_line(
                "msg-1",
                "2026-07-18T01:00:06Z",
                "claude-sonnet-5",
                [1, 1, 0, 0],
            ),
            claude_line(
                "msg-2",
                "2026-07-18T02:00:00.123Z",
                "claude-fable-5",
                [100, 0, 0, 0],
            ),
            // Zero-token lines are skipped entirely.
            claude_line(
                "msg-3",
                "2026-07-18T03:00:00Z",
                "claude-fable-5",
                [0, 0, 0, 0],
            ),
            "not json".to_string(),
        ]
        .join("\n");
        let mut messages = ClaudeMessages::new();
        parse_claude_lines(&text, &mut messages);
        assert_eq!(messages.len(), 2);
        assert_eq!(messages["msg-1"].tokens, 40);
        assert_eq!(messages["msg-2"].tokens, 100);

        let totals = claude_daily_totals(&messages);
        let day = day_key(messages["msg-1"].timestamp);
        assert_eq!(totals[&day]["claude-sonnet-5"], 40);
        assert_eq!(totals[&day]["claude-fable-5"], 100);
    }

    #[test]
    fn claude_parse_falls_back_to_uuid() {
        let line = serde_json::json!({
            "timestamp": "2026-07-18T01:00:00Z",
            "uuid": "uuid-only",
            "message": {"usage": {"input_tokens": 7}}
        })
        .to_string();
        let mut messages = ClaudeMessages::new();
        parse_claude_lines(&line, &mut messages);
        assert_eq!(messages["uuid-only"].tokens, 7);
        assert_eq!(messages["uuid-only"].model, "unknown");
    }

    fn codex_token_count(timestamp: &str, cumulative: i64, last: Option<i64>) -> String {
        let mut info = serde_json::json!({
            "total_token_usage": {"total_tokens": cumulative}
        });
        if let Some(last) = last {
            info["last_token_usage"] = serde_json::json!({"total_tokens": last});
        }
        serde_json::json!({
            "timestamp": timestamp,
            "payload": {"type": "token_count", "info": info}
        })
        .to_string()
    }

    #[test]
    fn codex_delta_rules() {
        let model_line = serde_json::json!({
            "timestamp": "2026-07-18T01:00:00Z",
            "payload": {"type": "turn_context", "model": "gpt-5.6-terra"}
        })
        .to_string();
        let text = [
            model_line,
            // First event without last_token_usage: cumulative itself.
            codex_token_count("2026-07-18T01:00:01Z", 100, None),
            // last_token_usage preferred over the diff.
            codex_token_count("2026-07-18T01:00:02Z", 180, Some(50)),
            // Unchanged cumulative means 0 even when last is present.
            codex_token_count("2026-07-18T01:00:03Z", 180, Some(999)),
            // No last_token_usage: cumulative diff fallback.
            codex_token_count("2026-07-18T01:00:04Z", 200, None),
        ]
        .join("\n");
        let parsed = parse_codex_lines(&text);
        let tokens: Vec<u64> = parsed.events.iter().map(|event| event.2).collect();
        assert_eq!(tokens, vec![100, 50, 20]);
        assert!(parsed.events.iter().all(|event| event.1 == "gpt-5.6-terra"));
    }

    #[test]
    fn codex_pre_declaration_events_use_first_declared_model() {
        let text = [
            // token_count before any model declaration (subagent pattern).
            codex_token_count("2026-07-18T01:00:00Z", 40, None),
            serde_json::json!({
                "timestamp": "2026-07-18T01:00:01Z",
                "payload": {"type": "turn_context", "model": "gpt-5.6-luna"}
            })
            .to_string(),
            codex_token_count("2026-07-18T01:00:02Z", 60, Some(20)),
        ]
        .join("\n");
        let parsed = parse_codex_lines(&text);
        assert_eq!(parsed.events[0].1, "gpt-5.6-luna");
        assert_eq!(parsed.events[1].1, "gpt-5.6-luna");
    }

    #[test]
    fn codex_model_less_file_is_unknown() {
        let parsed = parse_codex_lines(&codex_token_count("2026-07-18T01:00:00Z", 40, None));
        assert_eq!(parsed.events[0].1, "unknown");
    }

    #[test]
    fn codex_keeps_latest_rate_limits() {
        let with_limits = |timestamp: &str, percent: f64| {
            serde_json::json!({
                "timestamp": timestamp,
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": {"total_tokens": 1}},
                    "rate_limits": {"primary": {"used_percent": percent}}
                }
            })
            .to_string()
        };
        let text = [
            with_limits("2026-07-18T01:00:00Z", 10.0),
            with_limits("2026-07-18T02:00:00Z", 20.0),
        ]
        .join("\n");
        let parsed = parse_codex_lines(&text);
        let (timestamp, limits) = parsed.rate_limits.unwrap();
        assert_eq!(timestamp, "2026-07-18T02:00:00Z");
        assert_eq!(limits["primary"]["used_percent"].as_f64(), Some(20.0));
    }

    #[test]
    fn sorts_models_by_tokens_then_name() {
        let totals = HashMap::from([
            ("b-model".to_string(), 10u64),
            ("a-model".to_string(), 10u64),
            ("c-model".to_string(), 99u64),
        ]);
        let sorted = sorted_models(totals);
        let names: Vec<&str> = sorted.iter().map(|value| value.model.as_str()).collect();
        assert_eq!(names, vec!["c-model", "a-model", "b-model"]);
    }

    #[test]
    fn repeated_scan_reuses_directory_index_and_refreshes_known_files() {
        let (claude, codex) = temp_homes();
        let session = claude.join("projects/project/session.jsonl");
        let timestamp = chrono::Utc::now().to_rfc3339();
        fs::write(
            &session,
            claude_line("msg", &timestamp, "claude-test", [10, 0, 0, 0]),
        )
        .unwrap();
        let mut scanner = SessionScanner::new(&claude, &codex);

        DIRECTORY_READS.with(|reads| reads.set(0));
        let first = scanner.scan();
        let reads_after_first = DIRECTORY_READS.with(|reads| reads.get());
        assert_eq!(first.claude.tokens_today, 10);

        fs::write(
            &session,
            claude_line("msg", &timestamp, "claude-test", [25, 0, 0, 0]),
        )
        .unwrap();
        let second = scanner.scan();

        assert_eq!(second.claude.tokens_today, 25);
        assert_eq!(DIRECTORY_READS.with(|reads| reads.get()), reads_after_first);

        scanner.claude_files.last_full_refresh = Some(Instant::now() - FULL_INDEX_REFRESH_INTERVAL);
        scanner.codex_files.last_full_refresh = Some(Instant::now() - FULL_INDEX_REFRESH_INTERVAL);
        scanner.scan();
        assert!(DIRECTORY_READS.with(|reads| reads.get()) > reads_after_first);
    }

    #[test]
    fn directory_change_discovers_new_session_file() {
        let (claude, codex) = temp_homes();
        let project = claude.join("projects/project");
        let timestamp = chrono::Utc::now().to_rfc3339();
        fs::write(
            project.join("first.jsonl"),
            claude_line("first", &timestamp, "claude-test", [10, 0, 0, 0]),
        )
        .unwrap();
        let mut scanner = SessionScanner::new(&claude, &codex);

        DIRECTORY_READS.with(|reads| reads.set(0));
        assert_eq!(scanner.scan().claude.tokens_today, 10);
        let reads_after_first = DIRECTORY_READS.with(|reads| reads.get());
        fs::write(
            project.join("second.jsonl"),
            claude_line("second", &timestamp, "claude-test", [20, 0, 0, 0]),
        )
        .unwrap();
        if scanner.claude_files.directories[&project] == directory_mtime(&project) {
            // Keep the test deterministic on filesystems with coarse mtimes.
            scanner
                .claude_files
                .directories
                .insert(project.clone(), Some(UNIX_EPOCH));
        }

        let outcome = scanner.scan();

        assert_eq!(outcome.claude.tokens_today, 30);
        assert!(DIRECTORY_READS.with(|reads| reads.get()) > reads_after_first);
    }

    #[test]
    fn full_rebuild_reparses_file_when_len_and_mtime_match_cached_entry() {
        let (claude, codex) = temp_homes();
        let session = claude.join("projects/project/session.jsonl");
        let timestamp = chrono::Utc::now().to_rfc3339();
        let original = claude_line("msg", &timestamp, "claude-test", [10, 0, 0, 0]);
        let replacement = claude_line("msg", &timestamp, "claude-test", [25, 0, 0, 0]);
        assert_eq!(original.len(), replacement.len());
        fs::write(&session, original).unwrap();
        let mut scanner = SessionScanner::new(&claude, &codex);
        assert_eq!(scanner.scan().claude.tokens_today, 10);

        fs::write(&session, replacement).unwrap();
        let metadata = fs::metadata(&session).unwrap();
        let cached = scanner.claude_cache.get_mut(&session).unwrap();
        cached.mtime = metadata.modified().unwrap();
        cached.len = metadata.len();
        scanner.claude_files.last_full_refresh = Some(Instant::now() - FULL_INDEX_REFRESH_INTERVAL);

        assert_eq!(scanner.scan().claude.tokens_today, 25);
    }
}
