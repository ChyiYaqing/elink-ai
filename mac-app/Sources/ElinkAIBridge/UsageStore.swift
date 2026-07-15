import Foundation
import SQLite3

struct DailyModelUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String // "claude" / "codex"
    var model: String
    var tokens: Int
}

/// 每日各模型 token 用量的 SQLite 持久化，避免会话日志被清理后丢失历史
final class UsageStore {
    static let shared = UsageStore()

    private let queue = DispatchQueue(label: "elink.usage-store")
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let noResetMaxAge: TimeInterval = 6 * 60 * 60

    static var defaultPath: String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElinkAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.db").path
    }

    init(path: String = UsageStore.defaultPath) {
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                Log.info("usage db open failed: \(path)")
                sqlite3_close(db)
                db = nil
                return
            }
            sqlite3_busy_timeout(db, 1000)
            let create = """
            CREATE TABLE IF NOT EXISTS daily_model_usage (
                day TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (day, provider, model)
            )
            """
            if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
                Log.info("usage db create table failed")
            } else if !Self.columns(in: db).isSuperset(of: ["created_at", "updated_at"]) {
                Self.migrateTimestamps(in: db)
            }
            let createCache = """
            CREATE TABLE IF NOT EXISTS provider_usage_cache (
                provider TEXT NOT NULL,
                window_type TEXT NOT NULL,
                percent REAL NOT NULL,
                reset_at REAL,
                fetched_at REAL NOT NULL,
                PRIMARY KEY (provider, window_type)
            )
            """
            if sqlite3_exec(db, createCache, nil, nil, nil) != SQLITE_OK {
                Log.info("provider usage cache table create failed")
            }
        }
    }

    deinit { sqlite3_close(db) }

    /// 覆盖写入某天某 provider 的各模型用量（值为当日重算的总量而非增量）
    func record(day: String, provider: String, models: [String: Int]) {
        let rows = models.filter { $0.value > 0 }
        guard !rows.isEmpty else { return }
        queue.sync {
            guard db != nil else { return }
            let sql = """
            INSERT INTO daily_model_usage (day, provider, model, tokens)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(day, provider, model) DO UPDATE SET
                tokens = excluded.tokens,
                updated_at = CURRENT_TIMESTAMP
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            for (model, tokens) in rows {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, day, -1, Self.transient)
                sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
                sqlite3_bind_text(statement, 3, model, -1, Self.transient)
                sqlite3_bind_int64(statement, 4, Int64(tokens))
                sqlite3_step(statement)
            }
        }
    }

    func usage(provider: String, since day: String) -> [DailyModelUsage] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT day, model, tokens FROM daily_model_usage
            WHERE provider = ? AND day >= ? ORDER BY day, model
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            var result: [DailyModelUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let dayText = sqlite3_column_text(statement, 0),
                      let modelText = sqlite3_column_text(statement, 1) else { continue }
                result.append(DailyModelUsage(
                    day: String(cString: dayText),
                    provider: provider,
                    model: String(cString: modelText),
                    tokens: Int(sqlite3_column_int64(statement, 2))
                ))
            }
            return result
        }
    }

    /// 只保存配额窗口；OAuth 凭据永远不会写入数据库。
    func cacheUsage(provider: String, usage: ProviderUsage) {
        let fetchedAt = usage.fetchedAt ?? Date()
        let windows = [("primary", usage.primary), ("weekly", usage.weekly)]
            .filter { $0.1.percent != nil }
        queue.sync {
            guard db != nil else { return }
            var latestStatement: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT MAX(fetched_at) FROM provider_usage_cache WHERE provider = ?",
                -1,
                &latestStatement,
                nil
            ) == SQLITE_OK {
                sqlite3_bind_text(latestStatement, 1, provider, -1, Self.transient)
                if sqlite3_step(latestStatement) == SQLITE_ROW,
                   sqlite3_column_type(latestStatement, 0) != SQLITE_NULL,
                   sqlite3_column_double(latestStatement, 0) > fetchedAt.timeIntervalSince1970 {
                    sqlite3_finalize(latestStatement)
                    return
                }
            }
            sqlite3_finalize(latestStatement)

            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
            var succeeded = true

            var deleteStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM provider_usage_cache WHERE provider = ?", -1,
                                  &deleteStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStatement, 1, provider, -1, Self.transient)
                succeeded = sqlite3_step(deleteStatement) == SQLITE_DONE
            } else {
                succeeded = false
            }
            sqlite3_finalize(deleteStatement)

            let insert = """
            INSERT INTO provider_usage_cache
                (provider, window_type, percent, reset_at, fetched_at)
            VALUES (?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            if succeeded,
               sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
                for (windowType, window) in windows {
                    guard let percent = window.percent else { continue }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
                    sqlite3_bind_text(statement, 2, windowType, -1, Self.transient)
                    sqlite3_bind_double(statement, 3, percent)
                    if let resetAt = window.resetAt {
                        sqlite3_bind_double(statement, 4, resetAt.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    sqlite3_bind_double(statement, 5, fetchedAt.timeIntervalSince1970)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        succeeded = false
                        break
                    }
                }
            } else if succeeded {
                succeeded = false
            }
            sqlite3_finalize(statement)
            sqlite3_exec(db, succeeded ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        }
    }

    /// 启动时恢复仍未重置的窗口；没有 reset_at 的旧数据最多保留 6 小时。
    func cachedUsage(provider: String, now: Date = Date()) -> ProviderUsage? {
        queue.sync {
            guard db != nil else { return nil }
            let sql = """
            SELECT window_type, percent, reset_at, fetched_at
            FROM provider_usage_cache WHERE provider = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)

            var primary = UsageWindow()
            var weekly = UsageWindow()
            var latestFetchedAt: Date?
            while sqlite3_step(statement) == SQLITE_ROW,
                  let typeText = sqlite3_column_text(statement, 0) {
                let fetchedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let resetAt = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                if let resetAt, resetAt <= now { continue }
                if resetAt == nil, now.timeIntervalSince(fetchedAt) > Self.noResetMaxAge { continue }

                let window = UsageWindow(
                    percent: sqlite3_column_double(statement, 1),
                    resetMinutes: resetAt.map { max(0, Int($0.timeIntervalSince(now) / 60)) },
                    resetAt: resetAt
                )
                switch String(cString: typeText) {
                case "primary": primary = window
                case "weekly": weekly = window
                default: continue
                }
                if latestFetchedAt.map({ fetchedAt > $0 }) ?? true {
                    latestFetchedAt = fetchedAt
                }
            }
            guard primary.percent != nil || weekly.percent != nil else { return nil }
            return ProviderUsage(
                primary: primary,
                weekly: weekly,
                fetchedAt: latestFetchedAt,
                isCached: true
            )
        }
    }

    private static func columns(in db: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(daily_model_usage)", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 1) {
            result.insert(String(cString: name))
        }
        return result
    }

    private static func migrateTimestamps(in db: OpaquePointer?) {
        let sql = """
        BEGIN IMMEDIATE;
        CREATE TABLE daily_model_usage_v2 (
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (day, provider, model)
        );
        INSERT INTO daily_model_usage_v2 (day, provider, model, tokens)
        SELECT day, provider, model, tokens FROM daily_model_usage;
        DROP TABLE daily_model_usage;
        ALTER TABLE daily_model_usage_v2 RENAME TO daily_model_usage;
        COMMIT;
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            Log.info("usage db timestamp migration failed")
        }
    }
}
