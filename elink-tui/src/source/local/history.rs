use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use chrono::{Datelike, Days, NaiveDate};
use rusqlite::Connection;
use serde::Deserialize;

use super::db::{self, open_db};
use crate::model::ModelUsage;

/// day ("YYYY-MM-DD") -> model -> tokens
pub type DayTotals = HashMap<String, HashMap<String, u64>>;

const RETENTION_DAYS: u64 = 366;
const FLUSH_INTERVAL_SECONDS: i64 = 30;
/// `usage_metadata` key recording the timezone the buckets were computed in,
/// so a later timezone change can trigger a rebucket (see `needs_rebucket`).
pub const BUCKET_TIMEZONE_KEY: &str = "usage_bucket_timezone";

#[derive(Deserialize, Default)]
struct LegacyHistory {
    claude: DayTotals,
    codex: DayTotals,
}

/// day -> model -> category -> tokens.
pub type DayModelCategories = HashMap<String, HashMap<String, HashMap<String, u64>>>;

/// One flushed day: (provider, day, model totals, model -> category totals).
type DayWrite = (
    String,
    String,
    HashMap<String, u64>,
    HashMap<String, HashMap<String, u64>>,
);

#[derive(Default)]
struct HistoryData {
    claude: DayTotals,
    codex: DayTotals,
    gemini: DayTotals,
    /// Cost conversion needs the model and the category together; these ride
    /// the same dirty set as the totals so the two can never drift apart.
    claude_categories: DayModelCategories,
    codex_categories: DayModelCategories,
    gemini_categories: DayModelCategories,
    backfilled: bool,
    /// (provider, day) buckets changed in memory but not yet written.
    dirty: HashSet<(String, String)>,
    last_flush: i64,
    bucket_timezone: Option<String>,
}

/// Daily per-model token history stored in the shared `usage.db`
/// (`daily_model_usage` table), matching the mac-app's `UsageStore`. The
/// startup/timezone backfill scans old session logs off-thread; every poll
/// then rewrites only today's bucket. Writes are throttled and touch only
/// changed days.
pub struct History {
    conn: Mutex<Connection>,
    data: Mutex<HistoryData>,
}

impl History {
    /// Opens (or creates) the usage database at `path` and loads all stored
    /// day buckets into memory. A failure to open falls back to an empty,
    /// in-memory-only history so the dashboard still runs.
    pub fn new(path: PathBuf) -> Self {
        match open_db(&path) {
            Ok(conn) => {
                let (claude, codex, gemini) = load_days(&conn).unwrap_or_default();
                let (claude_categories, codex_categories, gemini_categories) =
                    load_model_categories(&conn).unwrap_or_default();
                let bucket_timezone = db::metadata_get(&conn, BUCKET_TIMEZONE_KEY).ok().flatten();
                Self {
                    conn: Mutex::new(conn),
                    data: Mutex::new(HistoryData {
                        claude,
                        codex,
                        gemini,
                        claude_categories,
                        codex_categories,
                        gemini_categories,
                        bucket_timezone,
                        ..HistoryData::default()
                    }),
                }
            }
            Err(_) => Self {
                conn: Mutex::new(open_db(Path::new(":memory:")).expect("in-memory sqlite")),
                data: Mutex::new(HistoryData::default()),
            },
        }
    }

    pub fn new_with_legacy(path: PathBuf, legacy_path: &Path) -> Self {
        let history = Self::new(path);
        history.import_legacy(legacy_path);
        history
    }

    /// Imports the former history JSON only when the shared database has no
    /// local daily rows. The JSON remains untouched as an upgrade backup.
    fn import_legacy(&self, path: &Path) {
        if !self.data().claude.is_empty() || !self.data().codex.is_empty() {
            return;
        }
        let Some(stored) = fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice::<LegacyHistory>(&data).ok())
        else {
            return;
        };
        if stored.claude.is_empty() && stored.codex.is_empty() {
            return;
        }
        let now = crate::util::epoch_now();
        let writes = all_writes(&stored.claude, &stored.codex);
        if self.persist(now, &writes, None).is_ok() {
            let mut data = self.data();
            data.claude = stored.claude;
            data.codex = stored.codex;
        }
    }

    fn data(&self) -> MutexGuard<'_, HistoryData> {
        self.data
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Replaces one day's bucket with the latest scan result (the scan is
    /// authoritative for days whose logs are still on disk).
    pub fn record_day(&self, provider: &str, day: &str, models: &[ModelUsage]) {
        self.record_day_inner(provider, day, models, &HashMap::new(), None);
    }

    /// Same as `record_day`, but refuses to mix a new timezone into buckets
    /// until the atomic backfill migration has committed its marker.
    pub fn record_day_in(
        &self,
        provider: &str,
        day: &str,
        models: &[ModelUsage],
        model_categories: &HashMap<String, HashMap<String, u64>>,
        timezone: &str,
    ) {
        self.record_day_inner(provider, day, models, model_categories, Some(timezone));
    }

    fn record_day_inner(
        &self,
        provider: &str,
        day: &str,
        models: &[ModelUsage],
        model_categories: &HashMap<String, HashMap<String, u64>>,
        timezone: Option<&str>,
    ) {
        let totals: HashMap<String, u64> = models
            .iter()
            .map(|usage| (usage.model.clone(), usage.tokens))
            .collect();
        let mut data = self.data();
        if timezone.is_some_and(|timezone| data.bucket_timezone.as_deref() != Some(timezone)) {
            return;
        }
        let unchanged_totals = match provider {
            "claude" => data.claude.get(day) == Some(&totals),
            "codex" => data.codex.get(day) == Some(&totals),
            "gemini" => data.gemini.get(day) == Some(&totals),
            _ => return,
        };
        let categories_changed = !model_categories.is_empty()
            && match provider {
                "claude" => data.claude_categories.get(day) != Some(model_categories),
                "codex" => data.codex_categories.get(day) != Some(model_categories),
                "gemini" => data.gemini_categories.get(day) != Some(model_categories),
                _ => false,
            };
        if unchanged_totals && !categories_changed {
            return;
        }
        if totals.is_empty() {
            // An empty scan must not erase a day that had data (e.g. logs
            // were cleaned up); only real totals overwrite.
            return;
        }
        match provider {
            "claude" => {
                data.claude.insert(day.to_string(), totals);
            }
            "codex" => {
                data.codex.insert(day.to_string(), totals);
            }
            "gemini" => {
                data.gemini.insert(day.to_string(), totals);
            }
            _ => return,
        }
        if !model_categories.is_empty() {
            let value = model_categories.clone();
            match provider {
                "claude" => {
                    data.claude_categories.insert(day.to_string(), value);
                }
                "codex" => {
                    data.codex_categories.insert(day.to_string(), value);
                }
                "gemini" => {
                    data.gemini_categories.insert(day.to_string(), value);
                }
                _ => {}
            }
        }
        data.dirty.insert((provider.to_string(), day.to_string()));
    }

    /// Today's model -> category usage for one provider, for cost conversion.
    pub fn day_model_categories(
        &self,
        provider: &str,
        day: &str,
    ) -> HashMap<String, HashMap<String, u64>> {
        let data = self.data();
        let categories = match provider {
            "claude" => &data.claude_categories,
            "codex" => &data.codex_categories,
            "gemini" => &data.gemini_categories,
            _ => return HashMap::new(),
        };
        categories.get(day).cloned().unwrap_or_default()
    }

    /// Merges a full backfill scan: every scanned day replaces the stored
    /// bucket, days absent from the scan (older, already-deleted logs) stay.
    pub fn merge_backfill(&self, claude: DayTotals, codex: DayTotals) {
        let mut data = self.data();
        for (day, models) in claude {
            data.dirty.insert(("claude".to_string(), day.clone()));
            data.claude.insert(day, models);
        }
        for (day, models) in codex {
            data.dirty.insert(("codex".to_string(), day.clone()));
            data.codex.insert(day, models);
        }
        data.backfilled = true;
    }

    /// Atomically rebuckets all local history and advances the timezone
    /// marker. When the source timezone is known, only the stored amount that
    /// existing logs cannot explain is retained on its old day; legacy data
    /// without a marker conserves each model's total deterministically.
    pub fn apply_backfill(
        &self,
        timezone: &str,
        target_claude: DayTotals,
        target_codex: DayTotals,
        old_explained: Option<(DayTotals, DayTotals)>,
        today: NaiveDate,
    ) -> bool {
        self.apply_backfill_all(
            timezone,
            target_claude,
            target_codex,
            DayTotals::new(),
            old_explained.map(|(c, x)| (c, x, DayTotals::new())),
            today,
        )
    }

    pub fn apply_backfill_all(
        &self,
        timezone: &str,
        target_claude: DayTotals,
        target_codex: DayTotals,
        target_gemini: DayTotals,
        old_explained: Option<(DayTotals, DayTotals, DayTotals)>,
        today: NaiveDate,
    ) -> bool {
        let mut data = self.data();
        let source = data.bucket_timezone.clone();
        let (mut claude, mut codex, mut gemini) = match source.as_deref() {
            Some(source) if source == timezone => (
                known_rebucket(&data.claude, &target_claude, &target_claude),
                known_rebucket(&data.codex, &target_codex, &target_codex),
                known_rebucket(&data.gemini, &target_gemini, &target_gemini),
            ),
            Some(_) => match old_explained {
                Some((old_claude, old_codex, old_gemini)) => (
                    known_rebucket(&data.claude, &old_claude, &target_claude),
                    known_rebucket(&data.codex, &old_codex, &target_codex),
                    known_rebucket(&data.gemini, &old_gemini, &target_gemini),
                ),
                None => (
                    legacy_rebucket(&data.claude, &target_claude),
                    legacy_rebucket(&data.codex, &target_codex),
                    legacy_rebucket(&data.gemini, &target_gemini),
                ),
            },
            None => (
                legacy_rebucket(&data.claude, &target_claude),
                legacy_rebucket(&data.codex, &target_codex),
                legacy_rebucket(&data.gemini, &target_gemini),
            ),
        };
        if let Some(cutoff) = today.checked_sub_days(Days::new(RETENTION_DAYS)) {
            let cutoff = cutoff.format("%Y-%m-%d").to_string();
            claude.retain(|day, _| day >= &cutoff);
            codex.retain(|day, _| day >= &cutoff);
            gemini.retain(|day, _| day >= &cutoff);
        }

        let mut conn = self.conn();
        let Ok(transaction) = conn.transaction() else {
            return false;
        };
        let saved = (|| -> rusqlite::Result<()> {
            transaction.execute(
                "DELETE FROM daily_model_usage WHERE provider IN ('claude', 'codex', 'gemini')",
                [],
            )?;
            for (provider, days) in [("claude", &claude), ("codex", &codex), ("gemini", &gemini)] {
                for (day, models) in days {
                    for (model, tokens) in models {
                        transaction.execute(
                            "INSERT INTO daily_model_usage (day, provider, model, tokens)
                             VALUES (?1, ?2, ?3, ?4)",
                            (day, provider, model, *tokens as i64),
                        )?;
                    }
                }
            }
            transaction.execute(
                "INSERT INTO usage_metadata (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (BUCKET_TIMEZONE_KEY, timezone),
            )?;
            Ok(())
        })()
        .and_then(|()| transaction.commit())
        .is_ok();
        drop(conn);
        if !saved {
            return false;
        }
        data.claude = claude;
        data.codex = codex;
        data.gemini = gemini;
        data.bucket_timezone = Some(timezone.to_string());
        data.backfilled = true;
        data.dirty.clear();
        true
    }

    pub fn backfilled(&self) -> bool {
        self.data().backfilled
    }

    pub fn provider_days(&self, provider: &str) -> DayTotals {
        let data = self.data();
        match provider {
            "claude" => data.claude.clone(),
            "codex" => data.codex.clone(),
            "gemini" => data.gemini.clone(),
            _ => DayTotals::new(),
        }
    }

    /// Records the timezone the current buckets were computed in.
    pub fn record_bucket_timezone(&self, timezone: &str) {
        let saved = {
            let conn = self.conn();
            db::metadata_set(&conn, BUCKET_TIMEZONE_KEY, timezone).is_ok()
        };
        if saved {
            self.data().bucket_timezone = Some(timezone.to_string());
        }
    }

    pub fn bucket_timezone(&self) -> Option<String> {
        self.data().bucket_timezone.clone()
    }

    /// True when the stored bucket timezone differs from `timezone`, meaning
    /// the daily buckets were computed under a different zone and a fresh
    /// backfill is needed to rebucket them (the mac-app's rebucket trigger).
    /// The very first run (no marker yet) is not a change.
    pub fn needs_rebucket(&self, timezone: &str) -> bool {
        self.data()
            .bucket_timezone
            .as_deref()
            .is_some_and(|stored| stored != timezone)
    }

    /// Writes changed buckets at most every 30 s and prunes days beyond the
    /// 366-day retention. On a database error the dirty set is kept so the
    /// next flush retries.
    pub fn flush_if_dirty(&self, now: i64, today: NaiveDate) {
        let (writes, cutoff) = {
            let mut data = self.data();
            if data.dirty.is_empty() || now - data.last_flush < FLUSH_INTERVAL_SECONDS {
                return;
            }
            let cutoff = today
                .checked_sub_days(Days::new(RETENTION_DAYS))
                .map(|date| date.format("%Y-%m-%d").to_string());
            if let Some(key) = &cutoff {
                data.claude.retain(|day, _| day.as_str() >= key.as_str());
                data.codex.retain(|day, _| day.as_str() >= key.as_str());
                data.gemini.retain(|day, _| day.as_str() >= key.as_str());
            }
            if let Some(key) = &cutoff {
                data.claude_categories
                    .retain(|day, _| day.as_str() >= key.as_str());
                data.codex_categories
                    .retain(|day, _| day.as_str() >= key.as_str());
                data.gemini_categories
                    .retain(|day, _| day.as_str() >= key.as_str());
            }
            let writes: Vec<DayWrite> = std::mem::take(&mut data.dirty)
                .into_iter()
                .map(|(provider, day)| {
                    let (bucket, categories) = match provider.as_str() {
                        "claude" => (data.claude.get(&day), data.claude_categories.get(&day)),
                        "codex" => (data.codex.get(&day), data.codex_categories.get(&day)),
                        "gemini" => (data.gemini.get(&day), data.gemini_categories.get(&day)),
                        _ => (None, None),
                    };
                    (
                        provider,
                        day,
                        bucket.cloned().unwrap_or_default(),
                        categories.cloned().unwrap_or_default(),
                    )
                })
                .collect();
            data.last_flush = now;
            (writes, cutoff)
        };

        if let Err(failed) = self.persist(now, &writes, cutoff.as_deref()) {
            // Restore the dirty set so the write is retried next cycle.
            let mut data = self.data();
            for (provider, day) in failed {
                data.dirty.insert((provider, day));
            }
        }
    }

    /// Replaces each changed day's rows in one transaction. Returns the dirty
    /// keys to restore if the transaction fails.
    fn persist(
        &self,
        _now: i64,
        writes: &[DayWrite],
        cutoff: Option<&str>,
    ) -> Result<(), Vec<(String, String)>> {
        let restore = || {
            writes
                .iter()
                .map(|(p, d, _, _)| (p.clone(), d.clone()))
                .collect()
        };
        let mut conn = self.conn();
        let transaction = conn.transaction().map_err(|_| restore())?;
        let result = (|| -> rusqlite::Result<()> {
            for (provider, day, models, categories) in writes {
                transaction.execute(
                    "DELETE FROM daily_model_usage WHERE provider = ?1 AND day = ?2",
                    (provider, day),
                )?;
                for (model, tokens) in models {
                    transaction.execute(
                        "INSERT INTO daily_model_usage (day, provider, model, tokens)
                         VALUES (?1, ?2, ?3, ?4)",
                        (day, provider, model, *tokens as i64),
                    )?;
                }
                // An empty breakdown means this scan had none to offer; leave
                // whatever is already stored rather than blanking the day.
                if categories.is_empty() {
                    continue;
                }
                transaction.execute(
                    "DELETE FROM daily_model_category_usage WHERE provider = ?1 AND day = ?2",
                    (provider, day),
                )?;
                for (model, buckets) in categories {
                    for (category, tokens) in buckets {
                        transaction.execute(
                            "INSERT INTO daily_model_category_usage
                             (day, provider, model, category, tokens)
                             VALUES (?1, ?2, ?3, ?4, ?5)",
                            (day, provider, model, category, *tokens as i64),
                        )?;
                    }
                }
            }
            if let Some(cutoff) = cutoff {
                transaction.execute("DELETE FROM daily_model_usage WHERE day < ?1", [cutoff])?;
                transaction.execute(
                    "DELETE FROM daily_model_category_usage WHERE day < ?1",
                    [cutoff],
                )?;
            }
            Ok(())
        })();
        result
            .and_then(|()| transaction.commit())
            .map_err(|_| restore())
    }
}

/// Loads the stored model x category breakdown, split by provider.
fn load_model_categories(
    conn: &Connection,
) -> rusqlite::Result<(DayModelCategories, DayModelCategories, DayModelCategories)> {
    let mut claude = DayModelCategories::new();
    let mut codex = DayModelCategories::new();
    let mut gemini = DayModelCategories::new();
    let mut statement = conn.prepare(
        "SELECT day, provider, model, category, tokens FROM daily_model_category_usage",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })?;
    for row in rows {
        let (day, provider, model, category, tokens) = row?;
        let days = match provider.as_str() {
            "claude" => &mut claude,
            "codex" => &mut codex,
            "gemini" => &mut gemini,
            _ => continue,
        };
        days.entry(day)
            .or_default()
            .entry(model)
            .or_default()
            .insert(category, tokens.max(0) as u64);
    }
    Ok((claude, codex, gemini))
}

/// Loads every stored day bucket, split by provider.
fn load_days(conn: &Connection) -> rusqlite::Result<(DayTotals, DayTotals, DayTotals)> {
    let mut claude = DayTotals::new();
    let mut codex = DayTotals::new();
    let mut gemini = DayTotals::new();
    let mut statement =
        conn.prepare("SELECT day, provider, model, tokens FROM daily_model_usage")?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, i64>(3)?,
        ))
    })?;
    for row in rows {
        let (day, provider, model, tokens) = row?;
        let days = match provider.as_str() {
            "claude" => &mut claude,
            "codex" => &mut codex,
            "gemini" => &mut gemini,
            _ => continue,
        };
        days.entry(day)
            .or_default()
            .insert(model, tokens.max(0) as u64);
    }
    Ok((claude, codex, gemini))
}

/// Legacy migration and backfill rescans carry model totals only — the
/// breakdown is left empty, and `persist` treats that as "nothing to say about
/// categories" rather than blanking whatever is already stored.
fn all_writes(claude: &DayTotals, codex: &DayTotals) -> Vec<DayWrite> {
    [("claude", claude), ("codex", codex)]
        .into_iter()
        .flat_map(|(provider, days)| {
            days.iter().map(move |(day, models)| {
                (
                    provider.to_string(),
                    day.clone(),
                    models.clone(),
                    HashMap::new(),
                )
            })
        })
        .collect()
}

fn positive_totals(totals: &DayTotals) -> DayTotals {
    totals
        .iter()
        .filter_map(|(day, models)| {
            let models: HashMap<String, u64> = models
                .iter()
                .filter(|(_, tokens)| **tokens > 0)
                .map(|(model, tokens)| (model.clone(), *tokens))
                .collect();
            (!models.is_empty()).then(|| (day.clone(), models))
        })
        .collect()
}

/// target + (stored - old logs), preserving only history the source logs can
/// no longer reconstruct.
fn known_rebucket(stored: &DayTotals, old_explained: &DayTotals, target: &DayTotals) -> DayTotals {
    let mut plan = positive_totals(target);
    for (day, models) in stored {
        for (model, tokens) in models {
            let explained = old_explained
                .get(day)
                .and_then(|models| models.get(model))
                .copied()
                .unwrap_or(0);
            let residue = tokens.saturating_sub(explained);
            if residue > 0 {
                let value = plan
                    .entry(day.clone())
                    .or_default()
                    .entry(model.clone())
                    .or_default();
                *value = value.saturating_add(residue);
            }
        }
    }
    plan
}

/// A legacy JSON file has no timezone marker. Preserve total tokens per model,
/// placing only the unexplained residue back on its original days in stable
/// date order while rebuilding all explainable events in the target zone.
fn legacy_rebucket(stored: &DayTotals, target: &DayTotals) -> DayTotals {
    let mut plan = positive_totals(target);
    let mut models = HashSet::new();
    stored
        .values()
        .chain(target.values())
        .for_each(|days| models.extend(days.keys().cloned()));
    let mut days: Vec<&String> = stored.keys().collect();
    days.sort();
    for model in models {
        let stored_total = stored.values().fold(0u64, |total, values| {
            total.saturating_add(values.get(&model).copied().unwrap_or(0))
        });
        let target_total = target.values().fold(0u64, |total, values| {
            total.saturating_add(values.get(&model).copied().unwrap_or(0))
        });
        let mut remaining = stored_total.saturating_sub(target_total);
        for day in &days {
            if remaining == 0 {
                break;
            }
            let candidate = stored
                .get(*day)
                .and_then(|values| values.get(&model))
                .copied()
                .unwrap_or(0)
                .saturating_sub(
                    target
                        .get(*day)
                        .and_then(|values| values.get(&model))
                        .copied()
                        .unwrap_or(0),
                );
            let retained = candidate.min(remaining);
            if retained > 0 {
                let value = plan
                    .entry((*day).clone())
                    .or_default()
                    .entry(model.clone())
                    .or_default();
                *value = value.saturating_add(retained);
                remaining -= retained;
            }
        }
    }
    plan
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatsRange {
    Week,
    Month,
    Year,
}

impl StatsRange {
    pub fn label(self) -> &'static str {
        match self {
            StatsRange::Week => "7d",
            StatsRange::Month => "30d",
            StatsRange::Year => "12mo",
        }
    }
}

pub struct RangeStats {
    /// One (label, tokens) entry per bar: days for week/month, months for year.
    pub series: Vec<(String, u64)>,
    pub total: u64,
    pub models: Vec<ModelUsage>,
}

/// Aggregates stored day buckets into the chart series for a range ending
/// today. Missing days render as zero bars so gaps stay visible.
pub fn range_stats(days: &DayTotals, range: StatsRange, today: NaiveDate) -> RangeStats {
    let mut series: Vec<(String, u64)> = Vec::new();
    let mut models: HashMap<String, u64> = HashMap::new();
    let mut total = 0u64;
    let mut add_day = |bucket: Option<&HashMap<String, u64>>| -> u64 {
        let mut day_total = 0u64;
        if let Some(bucket) = bucket {
            for (model, tokens) in bucket {
                *models.entry(model.clone()).or_insert(0) += tokens;
                day_total += tokens;
            }
        }
        total += day_total;
        day_total
    };
    match range {
        StatsRange::Week | StatsRange::Month => {
            let count = if range == StatsRange::Week { 7 } else { 30 };
            for offset in (0..count).rev() {
                let Some(date) = today.checked_sub_days(Days::new(offset)) else {
                    continue;
                };
                let key = date.format("%Y-%m-%d").to_string();
                let value = add_day(days.get(&key));
                let label = if range == StatsRange::Week {
                    date.format("%d").to_string()
                } else {
                    date.format("%m-%d").to_string()
                };
                series.push((label, value));
            }
        }
        StatsRange::Year => {
            // Last 12 calendar months including the current one.
            let mut months: Vec<(i32, u32)> = Vec::new();
            let (mut year, mut month) = (today.year(), today.month());
            for _ in 0..12 {
                months.push((year, month));
                if month == 1 {
                    year -= 1;
                    month = 12;
                } else {
                    month -= 1;
                }
            }
            months.reverse();
            let mut month_totals: Vec<u64> = vec![0; months.len()];
            for (day, bucket) in days {
                let Ok(date) = NaiveDate::parse_from_str(day, "%Y-%m-%d") else {
                    continue;
                };
                let Some(index) = months
                    .iter()
                    .position(|(y, m)| *y == date.year() && *m == date.month())
                else {
                    continue;
                };
                let mut day_total = 0u64;
                for (model, tokens) in bucket {
                    *models.entry(model.clone()).or_insert(0) += tokens;
                    day_total += tokens;
                }
                month_totals[index] += day_total;
                total += day_total;
            }
            for ((_, month), value) in months.iter().zip(month_totals) {
                series.push((format!("{month:02}"), value));
            }
        }
    }
    RangeStats {
        series,
        total,
        models: crate::source::local::sessions::sorted_models(models),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn temp_path() -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-history-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        std::env::temp_dir().join(unique).join("usage.db")
    }

    fn temp_history() -> History {
        History::new(temp_path())
    }

    fn usage(model: &str, tokens: u64) -> ModelUsage {
        ModelUsage {
            model: model.to_string(),
            tokens,
        }
    }

    fn categories(pairs: &[(&str, &[(&str, u64)])]) -> HashMap<String, HashMap<String, u64>> {
        pairs
            .iter()
            .map(|(model, buckets)| {
                (
                    (*model).to_string(),
                    buckets
                        .iter()
                        .map(|(key, value)| ((*key).to_string(), *value))
                        .collect(),
                )
            })
            .collect()
    }

    /// The breakdown must survive a flush and reopen, or the cost resets to
    /// zero every time the dashboard restarts.
    #[test]
    fn model_categories_survive_a_flush_and_reopen() {
        let path = temp_path();
        let day = "2026-07-19";
        {
            let history = History::new(path.clone());
            history.record_bucket_timezone("UTC");
            history.record_day_in(
                "claude",
                day,
                &[usage("claude-opus-5", 30)],
                &categories(&[("claude-opus-5", &[("input", 10), ("output", 20)])]),
                "UTC",
            );
            history.flush_if_dirty(
                crate::util::epoch_now() + 10_000,
                NaiveDate::from_ymd_opt(2026, 7, 19).unwrap(),
            );
        }
        let reopened = History::new(path);
        let stored = reopened.day_model_categories("claude", day);
        assert_eq!(stored["claude-opus-5"]["input"], 10);
        assert_eq!(stored["claude-opus-5"]["output"], 20);
    }

    /// A scan with no breakdown must not blank a day that already has one.
    #[test]
    fn empty_categories_do_not_erase_a_stored_breakdown() {
        let history = temp_history();
        let day = "2026-07-19";
        history.record_bucket_timezone("UTC");
        history.record_day_in(
            "claude",
            day,
            &[usage("claude-opus-5", 30)],
            &categories(&[("claude-opus-5", &[("input", 30)])]),
            "UTC",
        );
        history.record_day_in(
            "claude",
            day,
            &[usage("claude-opus-5", 45)],
            &HashMap::new(),
            "UTC",
        );
        assert_eq!(
            history.day_model_categories("claude", day)["claude-opus-5"]["input"],
            30
        );
    }

    /// Categories changing on their own still has to mark the day dirty,
    /// otherwise a same-total day silently never persists its breakdown.
    #[test]
    fn category_only_change_is_still_recorded() {
        let history = temp_history();
        let day = "2026-07-19";
        history.record_bucket_timezone("UTC");
        history.record_day_in(
            "claude",
            day,
            &[usage("claude-opus-5", 30)],
            &categories(&[("claude-opus-5", &[("input", 30)])]),
            "UTC",
        );
        // Same total, different split (a cache read reclassified as input).
        history.record_day_in(
            "claude",
            day,
            &[usage("claude-opus-5", 30)],
            &categories(&[("claude-opus-5", &[("input", 10), ("cache_read", 20)])]),
            "UTC",
        );
        let stored = history.day_model_categories("claude", day);
        assert_eq!(stored["claude-opus-5"]["cache_read"], 20);
    }

    #[test]
    fn records_replace_days_but_empty_scans_do_not_erase() {
        let history = temp_history();
        history.record_day("claude", "2026-07-19", &[usage("a", 10)]);
        history.record_day("claude", "2026-07-19", &[usage("a", 25), usage("b", 5)]);
        history.record_day("claude", "2026-07-19", &[]);

        let days = history.provider_days("claude");
        assert_eq!(days["2026-07-19"]["a"], 25);
        assert_eq!(days["2026-07-19"]["b"], 5);
    }

    #[test]
    fn flushes_and_reloads_across_instances() {
        let path = temp_path();
        let history = History::new(path.clone());
        history.record_day("codex", "2026-07-19", &[usage("gpt", 7)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        history.flush_if_dirty(1_000_000, today);
        drop(history);

        let reloaded = History::new(path);
        assert_eq!(reloaded.provider_days("codex")["2026-07-19"]["gpt"], 7);
        assert!(!reloaded.backfilled());
    }

    #[test]
    fn later_flush_overwrites_a_days_models() {
        let path = temp_path();
        let history = History::new(path.clone());
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        history.record_day("claude", "2026-07-19", &[usage("a", 10), usage("b", 4)]);
        history.flush_if_dirty(1_000_000, today);
        history.record_day("claude", "2026-07-19", &[usage("a", 25)]);
        history.flush_if_dirty(1_000_100, today);
        drop(history);

        let reloaded = History::new(path);
        let day = &reloaded.provider_days("claude")["2026-07-19"];
        assert_eq!(day["a"], 25);
        assert!(!day.contains_key("b"), "vanished model must be removed");
    }

    #[test]
    fn flush_prunes_days_beyond_retention() {
        let path = temp_path();
        let history = History::new(path.clone());
        history.record_day("claude", "2020-01-01", &[usage("old", 1)]);
        history.record_day("claude", "2026-07-19", &[usage("new", 2)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        history.flush_if_dirty(1_000_000, today);

        let days = history.provider_days("claude");
        assert!(!days.contains_key("2020-01-01"));
        assert!(days.contains_key("2026-07-19"));
        drop(history);
        let reloaded = History::new(path);
        assert!(!reloaded.provider_days("claude").contains_key("2020-01-01"));
    }

    #[test]
    fn backfill_merges_without_dropping_unscanned_days() {
        let history = temp_history();
        history.record_day("claude", "2020-01-02", &[usage("kept", 3)]);
        history.merge_backfill(
            DayTotals::from([(
                "2026-07-18".to_string(),
                HashMap::from([("a".to_string(), 9u64)]),
            )]),
            DayTotals::new(),
        );

        let days = history.provider_days("claude");
        assert_eq!(days["2026-07-18"]["a"], 9);
        assert_eq!(days["2020-01-02"]["kept"], 3);
        assert!(history.backfilled());
    }

    #[test]
    fn records_and_reports_bucket_timezone_change() {
        let history = temp_history();
        assert!(
            !history.needs_rebucket("UTC"),
            "no marker yet is not a change"
        );
        history.record_bucket_timezone("UTC");
        assert!(!history.needs_rebucket("UTC"));
        assert!(history.needs_rebucket("Asia/Shanghai"));
    }

    #[test]
    fn week_range_produces_seven_bars_ending_today() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        let days = DayTotals::from([
            (
                "2026-07-19".to_string(),
                HashMap::from([("a".to_string(), 10u64)]),
            ),
            (
                "2026-07-13".to_string(),
                HashMap::from([("a".to_string(), 5u64), ("b".to_string(), 1u64)]),
            ),
            // Outside the window; must be ignored.
            (
                "2026-07-12".to_string(),
                HashMap::from([("a".to_string(), 99u64)]),
            ),
        ]);

        let stats = range_stats(&days, StatsRange::Week, today);

        assert_eq!(stats.series.len(), 7);
        assert_eq!(stats.series[0], ("13".to_string(), 6));
        assert_eq!(stats.series[6], ("19".to_string(), 10));
        assert_eq!(stats.total, 16);
        assert_eq!(stats.models[0].model, "a");
        assert_eq!(stats.models[0].tokens, 15);
    }

    #[test]
    fn year_range_buckets_by_month() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        let days = DayTotals::from([
            (
                "2026-07-01".to_string(),
                HashMap::from([("a".to_string(), 10u64)]),
            ),
            (
                "2026-07-15".to_string(),
                HashMap::from([("a".to_string(), 20u64)]),
            ),
            (
                "2025-08-05".to_string(),
                HashMap::from([("b".to_string(), 7u64)]),
            ),
            // 13 months back; outside the window.
            (
                "2025-06-05".to_string(),
                HashMap::from([("b".to_string(), 99u64)]),
            ),
        ]);

        let stats = range_stats(&days, StatsRange::Year, today);

        assert_eq!(stats.series.len(), 12);
        assert_eq!(stats.series[11], ("07".to_string(), 30));
        assert_eq!(stats.series[0], ("08".to_string(), 7));
        assert_eq!(stats.total, 37);
    }

    #[test]
    fn flush_is_throttled_and_clears_dirty_on_success() {
        let history = temp_history();
        history.record_day("codex", "2026-07-19", &[usage("gpt", 7)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();

        // last_flush starts at 0; a flush within the interval is skipped.
        history.flush_if_dirty(10, today);
        assert!(
            !history.data().dirty.is_empty(),
            "throttled flush keeps dirty"
        );

        history.flush_if_dirty(1_000_000, today);
        assert!(
            history.data().dirty.is_empty(),
            "successful flush clears dirty"
        );
    }

    #[test]
    fn database_file_is_private() {
        let path = temp_path();
        let _history = History::new(path.clone());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    #[test]
    fn legacy_history_imports_once_into_shared_database() {
        let path = temp_path();
        let legacy = path.parent().unwrap().join("history.json");
        std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        std::fs::write(
            &legacy,
            r#"{"version":1,"claude":{"2026-07-19":{"sonnet":42}},"codex":{}}"#,
        )
        .unwrap();

        let history = History::new_with_legacy(path.clone(), &legacy);
        assert_eq!(history.provider_days("claude")["2026-07-19"]["sonnet"], 42);
        drop(history);

        // A changed legacy backup must not overwrite SQLite on later starts.
        std::fs::write(
            &legacy,
            r#"{"version":1,"claude":{"2026-07-19":{"sonnet":99}},"codex":{}}"#,
        )
        .unwrap();
        let reloaded = History::new_with_legacy(path, &legacy);
        assert_eq!(reloaded.provider_days("claude")["2026-07-19"]["sonnet"], 42);
    }

    #[test]
    fn timezone_rebucket_is_atomic_and_preserves_unexplained_residue() {
        let path = temp_path();
        let history = History::new(path.clone());
        let today = NaiveDate::from_ymd_opt(2026, 7, 20).unwrap();
        let utc = DayTotals::from([(
            "2026-07-19".to_string(),
            HashMap::from([("sonnet".to_string(), 100)]),
        )]);
        assert!(history.apply_backfill("UTC", utc, DayTotals::new(), None, today));

        let old_explained = DayTotals::from([(
            "2026-07-19".to_string(),
            HashMap::from([("sonnet".to_string(), 80)]),
        )]);
        let target = DayTotals::from([(
            "2026-07-20".to_string(),
            HashMap::from([("sonnet".to_string(), 80)]),
        )]);
        assert!(history.apply_backfill(
            "Asia/Singapore",
            target,
            DayTotals::new(),
            Some((old_explained, DayTotals::new())),
            today,
        ));
        drop(history);

        let reloaded = History::new(path);
        let days = reloaded.provider_days("claude");
        assert_eq!(days["2026-07-19"]["sonnet"], 20);
        assert_eq!(days["2026-07-20"]["sonnet"], 80);
        assert_eq!(
            reloaded.bucket_timezone().as_deref(),
            Some("Asia/Singapore")
        );
    }

    #[test]
    fn live_rows_wait_for_the_matching_timezone_marker() {
        let history = temp_history();
        history.record_day_in("claude", "2026-07-19", &[usage("a", 10)], &HashMap::new(), "UTC");
        assert!(history.provider_days("claude").is_empty());

        history.record_bucket_timezone("UTC");
        history.record_day_in("claude", "2026-07-19", &[usage("a", 10)], &HashMap::new(), "UTC");
        assert_eq!(history.provider_days("claude")["2026-07-19"]["a"], 10);
    }
}
