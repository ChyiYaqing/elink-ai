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
                PRIMARY KEY (day, provider, model)
            )
            """
            if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
                Log.info("usage db create table failed")
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
            let sql = "INSERT OR REPLACE INTO daily_model_usage (day, provider, model, tokens) VALUES (?, ?, ?, ?)"
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
}
