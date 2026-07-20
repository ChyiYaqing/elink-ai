use std::path::{Path, PathBuf};

use rusqlite::Connection;

use super::store::ensure_private_directory;

/// Opens the shared `usage.db`, matching the mac-app `UsageStore` schema so
/// daily token history, the quota window cache, and cluster state all live in
/// one SQLite file. Each caller (`History`, `QuotaStore`, `ClusterService`)
/// keeps its own connection; WAL plus a busy timeout keeps concurrent readers
/// and the 2 s poll/15 s sync writers from tripping over each other.
///
/// The state directory is created 0700 and the database file forced to 0600,
/// matching the permissions the JSON caches used before.
pub fn open_db(path: &Path) -> rusqlite::Result<Connection> {
    if let Some(directory) = path.parent().filter(|path| !path.as_os_str().is_empty()) {
        ensure_private_directory(directory).map_err(|error| {
            rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                Some(format!("cannot create state directory: {error}")),
            )
        })?;
    }
    let connection = Connection::open(path)?;
    restrict_file_mode(path);
    connection.busy_timeout(std::time::Duration::from_millis(5000))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    create_schema(&connection)?;
    restrict_file_mode(&sidecar_path(path, "-wal"));
    restrict_file_mode(&sidecar_path(path, "-shm"));
    Ok(connection)
}

/// Opens a private, in-memory-equivalent database for tests: a real file under
/// a unique temporary path so cross-instance reloads still exercise SQLite.
#[cfg(test)]
pub fn open_temp(label: &str) -> (Connection, std::path::PathBuf) {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let path = std::env::temp_dir()
        .join(format!(
            "elink-tui-db-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ))
        .join("usage.db");
    (open_db(&path).expect("open temp usage.db"), path)
}

fn restrict_file_mode(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(metadata) = std::fs::metadata(path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o600);
        let _ = std::fs::set_permissions(path, permissions);
    }
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

fn create_schema(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS daily_model_usage (
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (day, provider, model)
        );
        CREATE TABLE IF NOT EXISTS provider_usage_cache (
            provider TEXT NOT NULL,
            window_type TEXT NOT NULL,
            percent REAL NOT NULL,
            reset_at REAL,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (provider, window_type)
        );
        CREATE TABLE IF NOT EXISTS cluster_credentials (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            payload TEXT NOT NULL,
            updated_at REAL
        );
        CREATE TABLE IF NOT EXISTS cluster_nodes (
            node_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            endpoint TEXT,
            last_seen_at REAL,
            last_sync_at REAL
        );
        CREATE TABLE IF NOT EXISTS cluster_usage_snapshots (
            origin_node_id TEXT NOT NULL,
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            revision INTEGER NOT NULL,
            observed_at REAL NOT NULL,
            content_hash TEXT NOT NULL,
            PRIMARY KEY (origin_node_id, day, provider)
        );
        CREATE TABLE IF NOT EXISTS cluster_model_usage (
            origin_node_id TEXT NOT NULL,
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            PRIMARY KEY (origin_node_id, day, provider, model)
        );
        CREATE TABLE IF NOT EXISTS cluster_peers (
            endpoint TEXT PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS usage_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cluster_usage_provider_day
            ON cluster_usage_snapshots(provider, day);",
    )?;

    // Databases created by the first SQLite development build did not carry
    // the mac-app's content hash column. Add it in place before either side
    // writes the shared schema.
    let has_content_hash = connection
        .prepare("PRAGMA table_info(cluster_usage_snapshots)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(Result::ok)
        .any(|name| name == "content_hash");
    if !has_content_hash {
        connection.execute(
            "ALTER TABLE cluster_usage_snapshots
             ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''",
            [],
        )?;
    }
    Ok(())
}

/// Reads a `usage_metadata` value.
pub fn metadata_get(connection: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    connection
        .query_row(
            "SELECT value FROM usage_metadata WHERE key = ?1",
            [key],
            |row| row.get::<_, String>(0),
        )
        .map(Some)
        .or_else(|error| match error {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })
}

/// Writes a `usage_metadata` value.
pub fn metadata_set(connection: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    connection.execute(
        "INSERT INTO usage_metadata (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn opens_with_schema_and_private_permissions() {
        let (connection, path) = open_temp("schema");
        let tables: Vec<String> = connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for expected in [
            "cluster_credentials",
            "cluster_model_usage",
            "cluster_nodes",
            "cluster_peers",
            "cluster_usage_snapshots",
            "daily_model_usage",
            "provider_usage_cache",
            "usage_metadata",
        ] {
            assert!(tables.contains(&expected.to_string()), "missing {expected}");
        }
        let snapshot_columns: Vec<String> = connection
            .prepare("PRAGMA table_info(cluster_usage_snapshots)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(snapshot_columns.contains(&"content_hash".to_string()));
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
    fn metadata_roundtrips_and_upserts() {
        let (connection, _path) = open_temp("meta");
        assert_eq!(metadata_get(&connection, "tz").unwrap(), None);
        metadata_set(&connection, "tz", "UTC").unwrap();
        assert_eq!(
            metadata_get(&connection, "tz").unwrap().as_deref(),
            Some("UTC")
        );
        metadata_set(&connection, "tz", "Asia/Shanghai").unwrap();
        assert_eq!(
            metadata_get(&connection, "tz").unwrap().as_deref(),
            Some("Asia/Shanghai")
        );
    }
}
