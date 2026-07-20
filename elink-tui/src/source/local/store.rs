use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::Connection;
use serde::Deserialize;

use super::db::open_db;
use super::quota::{ProviderUsage, UsageWindow};

const NO_RESET_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;

#[derive(Deserialize, Default)]
struct LegacyWindow {
    percent: Option<f64>,
    reset_at: Option<i64>,
}

#[derive(Deserialize)]
struct LegacyProvider {
    primary: LegacyWindow,
    weekly: LegacyWindow,
    fetched_at: Option<i64>,
}

/// Quota window cache in the shared `usage.db` (`provider_usage_cache` table,
/// mirroring the mac-app's `UsageStore`) so a restart shows the last known
/// windows immediately. Both windows of a provider share one `fetched_at`.
pub struct QuotaStore {
    conn: Mutex<Connection>,
}

impl QuotaStore {
    pub fn new(path: PathBuf) -> Self {
        let conn = open_db(&path)
            .unwrap_or_else(|_| open_db(Path::new(":memory:")).expect("in-memory sqlite"));
        Self {
            conn: Mutex::new(conn),
        }
    }

    pub fn new_with_legacy(path: PathBuf, legacy_path: &Path) -> Self {
        let store = Self::new(path);
        store.import_legacy(legacy_path);
        store
    }

    /// Imports the former JSON cache only into an empty SQLite cache. The
    /// source file is deliberately retained as a recoverable backup.
    fn import_legacy(&self, path: &Path) {
        let empty = self
            .conn()
            .query_row("SELECT COUNT(*) FROM provider_usage_cache", [], |row| {
                row.get::<_, i64>(0)
            })
            .is_ok_and(|count| count == 0);
        if !empty {
            return;
        }
        let Some(json) = fs::read(path)
            .ok()
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        else {
            return;
        };
        for provider in ["claude", "codex"] {
            let Some(stored) = json
                .get(provider)
                .cloned()
                .and_then(|value| serde_json::from_value::<LegacyProvider>(value).ok())
            else {
                continue;
            };
            self.save(
                provider,
                &ProviderUsage {
                    primary: UsageWindow {
                        percent: stored.primary.percent,
                        reset_at: stored.primary.reset_at,
                    },
                    weekly: UsageWindow {
                        percent: stored.weekly.percent,
                        reset_at: stored.weekly.reset_at,
                    },
                    fetched_at: stored.fetched_at,
                    ..ProviderUsage::default()
                },
            );
        }
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Expired windows are dropped on read: `reset_at <= now` discards the
    /// window, and a window without a reset time is trusted for six hours.
    pub fn load(&self, provider: &str, now: i64) -> Option<ProviderUsage> {
        let conn = self.conn();
        let mut statement = conn
            .prepare(
                "SELECT window_type, percent, reset_at, fetched_at
                 FROM provider_usage_cache WHERE provider = ?1",
            )
            .ok()?;
        let mut primary = UsageWindow::default();
        let mut weekly = UsageWindow::default();
        let mut fetched_at: Option<i64> = None;
        let rows = statement
            .query_map([provider], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<f64>>(1)?,
                    row.get::<_, Option<f64>>(2)?,
                    row.get::<_, Option<f64>>(3)?,
                ))
            })
            .ok()?;
        for row in rows {
            let (window_type, percent, reset_at, row_fetched) = row.ok()?;
            let reset_at = reset_at.map(|value| value as i64);
            let row_fetched = row_fetched.map(|value| value as i64);
            fetched_at = fetched_at.max(row_fetched);
            let window = UsageWindow { percent, reset_at };
            match window_type.as_str() {
                "primary" => primary = window,
                "weekly" => weekly = window,
                _ => {}
            }
        }
        let fetched_at = fetched_at?;
        let usable = |window: UsageWindow| -> UsageWindow {
            let keep = match window.reset_at {
                Some(reset_at) => reset_at > now,
                None => now - fetched_at <= NO_RESET_MAX_AGE_SECONDS,
            };
            if keep {
                window
            } else {
                UsageWindow::default()
            }
        };
        let primary = usable(primary);
        let weekly = usable(weekly);
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

    /// A result without any window must not clobber the persisted cache, and
    /// an older observation (e.g. the statusline-file fallback) must not
    /// overwrite a fresher one.
    pub fn save(&self, provider: &str, usage: &ProviderUsage) {
        if usage.primary.percent.is_none() && usage.weekly.percent.is_none() {
            return;
        }
        let mut conn = self.conn();
        let existing_fetched_at: Option<i64> = conn
            .query_row(
                "SELECT MAX(fetched_at) FROM provider_usage_cache WHERE provider = ?1",
                [provider],
                |row| row.get::<_, Option<f64>>(0),
            )
            .ok()
            .flatten()
            .map(|value| value as i64);
        if let (Some(existing), Some(new)) = (existing_fetched_at, usage.fetched_at) {
            if existing > new {
                return;
            }
        }
        let fetched_at = usage.fetched_at.unwrap_or_else(crate::util::epoch_now) as f64;
        let Ok(transaction) = conn.transaction() else {
            return;
        };
        if transaction
            .execute(
                "DELETE FROM provider_usage_cache WHERE provider = ?1",
                [provider],
            )
            .is_err()
        {
            return;
        }
        for (window_type, window) in [("primary", &usage.primary), ("weekly", &usage.weekly)] {
            let Some(percent) = window.percent else {
                continue;
            };
            if transaction
                .execute(
                    "INSERT INTO provider_usage_cache
                        (provider, window_type, percent, reset_at, fetched_at)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    rusqlite::params![
                        provider,
                        window_type,
                        percent,
                        window.reset_at.map(|value| value as f64),
                        fetched_at,
                    ],
                )
                .is_err()
            {
                return;
            }
        }
        let _ = transaction.commit();
    }
}

pub(crate) fn ensure_private_directory(directory: &Path) -> io::Result<()> {
    if directory.as_os_str().is_empty() {
        return Ok(());
    }
    match fs::metadata(directory) {
        Ok(metadata) if metadata.is_dir() => return Ok(()),
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "cache parent exists and is not a directory",
            ));
        }
        Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
        Err(_) => {}
    }
    if let Some(parent) = directory.parent().filter(|path| *path != directory) {
        ensure_private_directory(parent)?;
    }
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    match builder.create(directory) {
        Ok(()) => fs::set_permissions(directory, fs::Permissions::from_mode(0o700)),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            if fs::metadata(directory)?.is_dir() {
                Ok(())
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU32, Ordering};

    const NOW: i64 = 1_783_933_200;

    fn temp_store_path() -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-store-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        std::env::temp_dir().join(unique).join("usage.db")
    }

    fn temp_store() -> QuotaStore {
        QuotaStore::new(temp_store_path())
    }

    fn usage(percent: f64, reset_at: Option<i64>, fetched_at: i64) -> ProviderUsage {
        ProviderUsage {
            primary: UsageWindow {
                percent: Some(percent),
                reset_at,
            },
            weekly: UsageWindow::default(),
            error: None,
            fetched_at: Some(fetched_at),
            is_cached: false,
        }
    }

    #[test]
    fn roundtrips_and_marks_cached() {
        let store = temp_store();
        store.save("claude", &usage(43.0, Some(NOW + 600), NOW));

        let loaded = store.load("claude", NOW).expect("cache must load");

        assert_eq!(loaded.primary.percent, Some(43.0));
        assert_eq!(loaded.fetched_at, Some(NOW));
        assert!(loaded.is_cached);
        assert!(store.load("codex", NOW).is_none());
    }

    #[test]
    fn drops_expired_and_stale_windows_on_load() {
        let store = temp_store();
        store.save("claude", &usage(43.0, Some(NOW - 1), NOW - 100));
        assert!(store.load("claude", NOW).is_none());

        store.save(
            "codex",
            &usage(20.0, None, NOW - NO_RESET_MAX_AGE_SECONDS - 1),
        );
        assert!(store.load("codex", NOW).is_none());
        let fresh = store.load("codex", NOW - NO_RESET_MAX_AGE_SECONDS);
        assert_eq!(fresh.expect("within age").primary.percent, Some(20.0));
    }

    #[test]
    fn empty_result_does_not_clobber_and_older_does_not_overwrite() {
        let store = temp_store();
        store.save("claude", &usage(43.0, Some(NOW + 600), NOW));

        store.save("claude", &ProviderUsage::default());
        assert_eq!(
            store.load("claude", NOW).expect("kept").primary.percent,
            Some(43.0)
        );

        store.save("claude", &usage(10.0, Some(NOW + 600), NOW - 3600));
        assert_eq!(
            store.load("claude", NOW).expect("kept").primary.percent,
            Some(43.0)
        );

        store.save("claude", &usage(50.0, Some(NOW + 600), NOW + 60));
        assert_eq!(
            store.load("claude", NOW).expect("updated").primary.percent,
            Some(50.0)
        );
    }

    #[test]
    fn save_reload_persists_the_latest_window() {
        let path = temp_store_path();
        let store = QuotaStore::new(path.clone());
        store.save("claude", &usage(10.0, Some(NOW + 600), NOW));
        store.save("claude", &usage(20.0, Some(NOW + 600), NOW + 1));
        drop(store);

        let reloaded = QuotaStore::new(path);
        assert_eq!(
            reloaded.load("claude", NOW).expect("kept").primary.percent,
            Some(20.0)
        );
    }

    #[test]
    fn save_creates_private_parent_and_database_file() {
        let path = temp_store_path();
        let store = QuotaStore::new(path.clone());
        store.save("claude", &usage(10.0, Some(NOW + 600), NOW));

        let directory = path.parent().unwrap();
        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn imports_legacy_json_without_overwriting_newer_sqlite_rows() {
        let path = temp_store_path();
        let legacy = path.parent().unwrap().join("quota.json");
        fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        fs::write(
            &legacy,
            format!(
                r#"{{"claude":{{"primary":{{"percent":43.0,"reset_at":{}}},"weekly":{{"percent":null,"reset_at":null}},"fetched_at":{}}}}}"#,
                NOW + 600,
                NOW
            ),
        )
        .unwrap();

        let store = QuotaStore::new_with_legacy(path.clone(), &legacy);
        assert_eq!(
            store.load("claude", NOW).unwrap().primary.percent,
            Some(43.0)
        );
        store.save("claude", &usage(50.0, Some(NOW + 600), NOW + 1));
        drop(store);

        let reloaded = QuotaStore::new_with_legacy(path, &legacy);
        assert_eq!(
            reloaded.load("claude", NOW).unwrap().primary.percent,
            Some(50.0)
        );
    }
}
