use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::quota::{ProviderUsage, UsageWindow};

const NO_RESET_MAX_AGE_SECONDS: i64 = 6 * 60 * 60;
const MAX_TEMP_FILE_ATTEMPTS: usize = 16;
static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize, Deserialize, Default)]
struct StoredWindow {
    percent: Option<f64>,
    reset_at: Option<i64>,
}

#[derive(Serialize, Deserialize)]
struct StoredProvider {
    primary: StoredWindow,
    weekly: StoredWindow,
    fetched_at: Option<i64>,
}

/// JSON quota cache so a restart shows the last known windows immediately
/// (mirrors UsageStore.cacheUsage/cachedUsage). The state directory is 0700
/// and the file 0600, matching the repo's usage.db permissions.
pub struct QuotaStore {
    path: PathBuf,
}

impl QuotaStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// Expired windows are dropped on read: `reset_at <= now` discards the
    /// window, and a window without a reset time is trusted for six hours.
    pub fn load(&self, provider: &str, now: i64) -> Option<ProviderUsage> {
        let data = fs::read(&self.path).ok()?;
        let json: Value = serde_json::from_slice(&data).ok()?;
        let stored: StoredProvider = serde_json::from_value(json.get(provider)?.clone()).ok()?;
        let fetched_at = stored.fetched_at?;
        let window = |window: StoredWindow| -> UsageWindow {
            let usable = match window.reset_at {
                Some(reset_at) => reset_at > now,
                None => now - fetched_at <= NO_RESET_MAX_AGE_SECONDS,
            };
            if usable {
                UsageWindow {
                    percent: window.percent,
                    reset_at: window.reset_at,
                }
            } else {
                UsageWindow::default()
            }
        };
        let primary = window(stored.primary);
        let weekly = window(stored.weekly);
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
        let mut json: Value = fs::read(&self.path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
        if !json.is_object() {
            json = Value::Object(serde_json::Map::new());
        }
        let existing_fetched_at = json
            .get(provider)
            .and_then(|value| value.get("fetched_at"))
            .and_then(Value::as_i64);
        if let (Some(existing), Some(new)) = (existing_fetched_at, usage.fetched_at) {
            if existing > new {
                return;
            }
        }
        let stored = StoredProvider {
            primary: StoredWindow {
                percent: usage.primary.percent,
                reset_at: usage.primary.reset_at,
            },
            weekly: StoredWindow {
                percent: usage.weekly.percent,
                reset_at: usage.weekly.reset_at,
            },
            fetched_at: usage.fetched_at,
        };
        let Ok(value) = serde_json::to_value(&stored) else {
            return;
        };
        json[provider] = value;
        let Ok(text) = serde_json::to_string(&json) else {
            return;
        };
        let _ = write_restricted(&self.path, &text);
    }
}

/// Writes a private cache through a same-directory temporary file, then
/// atomically replaces the destination. Existing parent directories retain
/// their permissions; only directories created here are set to 0700.
pub(crate) fn write_restricted(path: &Path, text: &str) -> io::Result<()> {
    write_restricted_with_counter(path, text, &TEMP_FILE_COUNTER)
}

fn write_restricted_with_counter(path: &Path, text: &str, counter: &AtomicU64) -> io::Result<()> {
    if let Some(directory) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
        ensure_private_directory(directory)?;
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    let mut opened = None;
    for attempt in 0..MAX_TEMP_FILE_ATTEMPTS {
        let temporary = temporary_path(path, counter.fetch_add(1, Ordering::Relaxed))?;
        match options.open(&temporary) {
            Ok(file) => {
                opened = Some((temporary, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if attempt + 1 == MAX_TEMP_FILE_ATTEMPTS {
                    return Err(error);
                }
            }
            Err(error) => return Err(error),
        }
    }
    let (temporary, mut file) = opened.expect("temporary-file attempts must be positive");
    let result = (|| {
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn ensure_private_directory(directory: &Path) -> io::Result<()> {
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

fn temporary_path(path: &Path, counter: u64) -> io::Result<PathBuf> {
    let file_name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "cache path has no file name")
    })?;
    let mut name = OsString::from(".");
    name.push(file_name);
    name.push(format!(".{}-{}.tmp", std::process::id(), counter));
    Ok(path.with_file_name(name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::sync::atomic::{AtomicU32, Ordering};

    const NOW: i64 = 1_783_933_200;

    fn temp_store() -> QuotaStore {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = format!(
            "elink-tui-store-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        QuotaStore::new(std::env::temp_dir().join(unique).join("quota.json"))
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
    fn save_preserves_existing_parent_mode_and_replaces_atomically() {
        let store = temp_store();
        let directory = store.path.parent().unwrap();
        fs::create_dir_all(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o750)).unwrap();

        store.save("claude", &usage(10.0, Some(NOW + 600), NOW));
        let first_inode = fs::metadata(&store.path).unwrap().ino();
        store.save("claude", &usage(20.0, Some(NOW + 600), NOW + 1));

        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o750
        );
        let metadata = fs::metadata(&store.path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_ne!(metadata.ino(), first_inode);
    }

    #[test]
    fn save_creates_private_parent_and_leaves_no_temporary_file() {
        let store = temp_store();
        let directory = store.path.parent().unwrap();

        store.save("claude", &usage(10.0, Some(NOW + 600), NOW));

        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&store.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let names: Vec<_> = fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![store.path.file_name().unwrap()]);
    }

    #[test]
    fn occupied_temporary_name_is_preserved_and_write_retries() {
        let store = temp_store();
        let directory = store.path.parent().unwrap();
        fs::create_dir_all(directory).unwrap();
        let counter = AtomicU64::new(0);
        let occupied = temporary_path(&store.path, 0).unwrap();
        fs::write(&occupied, "occupied").unwrap();

        write_restricted_with_counter(&store.path, "replacement", &counter)
            .expect("a colliding temporary name should be retried");

        assert_eq!(fs::read_to_string(&store.path).unwrap(), "replacement");
        assert_eq!(fs::read_to_string(occupied).unwrap(), "occupied");
    }
}
