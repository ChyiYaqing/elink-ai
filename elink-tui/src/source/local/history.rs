use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use chrono::{Datelike, Days, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::model::ModelUsage;

/// day ("YYYY-MM-DD") -> model -> tokens
pub type DayTotals = HashMap<String, HashMap<String, u64>>;

const RETENTION_DAYS: u64 = 366;
const FLUSH_INTERVAL_SECONDS: i64 = 30;

#[derive(Serialize, Deserialize, Default)]
struct StoredHistory {
    version: u32,
    claude: DayTotals,
    codex: DayTotals,
}

#[derive(Default)]
struct HistoryData {
    claude: DayTotals,
    codex: DayTotals,
    backfilled: bool,
    dirty: bool,
    last_flush: i64,
}

/// Daily per-model token history persisted as JSON (lightweight version of
/// the mac-app's SQLite usage.db — no timezone migration machinery). The
/// startup backfill scans old session logs once; every poll then rewrites
/// only today's bucket.
pub struct History {
    path: PathBuf,
    data: Mutex<HistoryData>,
}

impl History {
    pub fn new(path: PathBuf) -> Self {
        let stored: StoredHistory = fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        Self {
            path,
            data: Mutex::new(HistoryData {
                claude: stored.claude,
                codex: stored.codex,
                ..HistoryData::default()
            }),
        }
    }

    fn data(&self) -> MutexGuard<'_, HistoryData> {
        self.data
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Replaces one day's bucket with the latest scan result (the scan is
    /// authoritative for days whose logs are still on disk).
    pub fn record_day(&self, provider: &str, day: &str, models: &[ModelUsage]) {
        let totals: HashMap<String, u64> = models
            .iter()
            .map(|usage| (usage.model.clone(), usage.tokens))
            .collect();
        let mut data = self.data();
        let days = match provider {
            "claude" => &mut data.claude,
            "codex" => &mut data.codex,
            _ => return,
        };
        if days.get(day) == Some(&totals) {
            return;
        }
        if totals.is_empty() {
            // An empty scan must not erase a day that had data (e.g. logs
            // were cleaned up); only real totals overwrite.
            return;
        }
        days.insert(day.to_string(), totals);
        data.dirty = true;
    }

    /// Merges a full backfill scan: every scanned day replaces the stored
    /// bucket, days absent from the scan (older, already-deleted logs) stay.
    pub fn merge_backfill(&self, claude: DayTotals, codex: DayTotals) {
        let mut data = self.data();
        for (day, models) in claude {
            data.claude.insert(day, models);
        }
        for (day, models) in codex {
            data.codex.insert(day, models);
        }
        data.backfilled = true;
        data.dirty = true;
    }

    pub fn backfilled(&self) -> bool {
        self.data().backfilled
    }

    pub fn provider_days(&self, provider: &str) -> DayTotals {
        let data = self.data();
        match provider {
            "claude" => data.claude.clone(),
            "codex" => data.codex.clone(),
            _ => DayTotals::new(),
        }
    }

    /// Writes at most every 30 s and prunes days beyond the 366-day retention.
    pub fn flush_if_dirty(&self, now: i64, today: NaiveDate) {
        let (stored, previous_last_flush) = {
            let mut data = self.data();
            if !data.dirty || now - data.last_flush < FLUSH_INTERVAL_SECONDS {
                return;
            }
            let previous_last_flush = data.last_flush;
            if let Some(cutoff) = today.checked_sub_days(Days::new(RETENTION_DAYS)) {
                let key = cutoff.format("%Y-%m-%d").to_string();
                data.claude.retain(|day, _| day.as_str() >= key.as_str());
                data.codex.retain(|day, _| day.as_str() >= key.as_str());
            }
            data.dirty = false;
            data.last_flush = now;
            (
                StoredHistory {
                    version: 1,
                    claude: data.claude.clone(),
                    codex: data.codex.clone(),
                },
                previous_last_flush,
            )
        };
        let result = serde_json::to_string(&stored)
            .map_err(std::io::Error::other)
            .and_then(|text| super::store::write_restricted(&self.path, &text));
        if result.is_err() {
            let mut data = self.data();
            data.dirty = true;
            data.last_flush = previous_last_flush;
        }
    }
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

    fn temp_history() -> History {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-history-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        History::new(std::env::temp_dir().join(unique).join("history.json"))
    }

    fn usage(model: &str, tokens: u64) -> ModelUsage {
        ModelUsage {
            model: model.to_string(),
            tokens,
        }
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
        let history = temp_history();
        history.record_day("codex", "2026-07-19", &[usage("gpt", 7)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        history.flush_if_dirty(1_000_000, today);

        let reloaded = History::new(history.path.clone());
        assert_eq!(reloaded.provider_days("codex")["2026-07-19"]["gpt"], 7);
        assert!(!reloaded.backfilled());
    }

    #[test]
    fn flush_prunes_days_beyond_retention() {
        let history = temp_history();
        history.record_day("claude", "2020-01-01", &[usage("old", 1)]);
        history.record_day("claude", "2026-07-19", &[usage("new", 2)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();
        history.flush_if_dirty(1_000_000, today);

        let days = history.provider_days("claude");
        assert!(!days.contains_key("2020-01-01"));
        assert!(days.contains_key("2026-07-19"));
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
    fn failed_flush_stays_dirty_and_can_retry_immediately() {
        let history = temp_history();
        let directory = history.path.parent().unwrap().to_path_buf();
        fs::create_dir_all(directory.parent().unwrap()).unwrap();
        fs::write(&directory, "blocks directory creation").unwrap();
        history.record_day("codex", "2026-07-19", &[usage("gpt", 7)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();

        history.flush_if_dirty(1_000_000, today);
        assert!(history.data().dirty);

        fs::remove_file(&directory).unwrap();
        history.flush_if_dirty(1_000_000, today);
        assert!(history.path.exists());
        assert!(!history.data().dirty);
    }

    #[test]
    fn flush_preserves_existing_parent_mode() {
        let history = temp_history();
        let directory = history.path.parent().unwrap();
        fs::create_dir_all(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o750)).unwrap();
        history.record_day("codex", "2026-07-19", &[usage("gpt", 7)]);
        let today = NaiveDate::from_ymd_opt(2026, 7, 19).unwrap();

        history.flush_if_dirty(1_000_000, today);

        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o750
        );
        assert_eq!(
            fs::metadata(&history.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
