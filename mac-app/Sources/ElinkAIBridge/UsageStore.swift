import Foundation
import SQLite3

struct DailyModelUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String // "claude" / "codex"
    var model: String
    var tokens: Int
    var nodeID: String? = nil
}

typealias DailyUsageTotals = [String: [String: Int]]

struct UsageHistoryTotals: Equatable {
    var claude: DailyUsageTotals
    var codex: DailyUsageTotals

    func values(for provider: String) -> DailyUsageTotals {
        provider == "claude" ? claude : codex
    }

    var isEmpty: Bool { claude.isEmpty && codex.isEmpty }
}

enum UsageBucketMigrationResult: Equatable {
    case applied
    case alreadyCurrent
    case sourceChanged
    case failed
}

/// 每日各模型 token 用量的 SQLite 持久化，避免会话日志被清理后丢失历史
final class UsageStore {
    static let shared = UsageStore()

    private let queue = DispatchQueue(label: "elink.usage-store")
    private let databasePath: String
    private var db: OpaquePointer?
    private var clusterNodeID: String?
    private var clusterAggregationEnabled = false
    // 每次 resetRemoteClusterData（切换/退出集群）时 +1。同步回包携带发起时的纪元，
    // 在同一队列内校验后才落库，彻底关闭“校验后、写入前被 reset 插入”的竞态窗口
    private var clusterDataEpochValue = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let noResetMaxAge: TimeInterval = 6 * 60 * 60
    private static let bucketTimeZoneMetadataKey = "usage_bucket_timezone"
    private static let bucketLegacyUnknownMetadataKey = "usage_bucket_legacy_unknown"
    var onClusterUsageChange: (([ClusterSnapshotDescriptor]) -> Void)?

    static var defaultPath: String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElinkAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        return directory.appendingPathComponent("usage.db").path
    }

    init(path: String = UsageStore.defaultPath) {
        databasePath = path
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                Log.error("usage db open failed: \(path)", category: "storage")
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
                Log.error("usage db create table failed", category: "storage")
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
                Log.error("provider usage cache table create failed", category: "storage")
            }
            Self.createClusterTables(in: db)
            Self.protectDatabaseFiles(at: path)
        }
    }

    deinit { sqlite3_close(db) }

    /// 覆盖写入某天某 provider 的各模型用量（值为当日重算的总量而非增量）。
    /// 空集只会来自暂时读不到日志的场景，直接忽略，避免清掉已有数据并向集群广播空快照。
    /// preservingResidue 供实时路径使用：当日日志被删除后，已入库的、现存日志
    /// 解释不了的部分按残差规则保留（逐模型取较大值），与 backfill 语义一致。
    func record(day: String, provider: String, models: [String: Int],
                expectedBucketTimeZone: String?, preservingResidue: Bool = false) {
        let rows = models.filter { $0.value > 0 }
        guard !rows.isEmpty else { return }
        // daily 表和集群快照必须在同一个事务里换新，避免并发或中断造成两者不一致
        let descriptor: ClusterSnapshotDescriptor? = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedBucketTimeZone else {
                _ = finishTransactionLocked(false)
                return nil
            }
            var effective = rows
            if preservingResidue {
                guard let stored = dayModelsLocked(day: day, provider: provider) else {
                    _ = finishTransactionLocked(false)
                    return nil
                }
                for (model, tokens) in stored where tokens > (effective[model] ?? 0) {
                    effective[model] = tokens
                }
            }
            var succeeded = replaceDailyRowsLocked(day: day, provider: provider, rows: effective)
            var result: ClusterSnapshotDescriptor?
            if succeeded {
                switch recordLocalSnapshotLocked(day: day, provider: provider, models: effective) {
                case let .changed(value): result = value
                case .unchanged: break
                case .failed: succeeded = false
                }
            }
            return finishTransactionLocked(succeeded) ? result : nil
        }
        // descriptor 仅在模型集合真正变化时返回，避免设备高频轮询导致统计页反复重载
        if let descriptor {
            onClusterUsageChange?([descriptor])
            Self.notifyDataChanged()
        }
    }

    /// COMMIT 也可能失败；任何一步失败都必须回滚，绝不提交半套数据
    private func finishTransactionLocked(_ succeeded: Bool) -> Bool {
        if succeeded, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            return true
        }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        return false
    }

    /// 覆盖语义写入 daily 表：UPSERT 当前模型集，并删除当日已消失的模型行，
    /// 否则周/月/年统计会残留旧值。调用方须在 queue 内、已开启事务时调用。
    private func replaceDailyRowsLocked(day: String, provider: String,
                                        rows: [String: Int]) -> Bool {
        let sql = """
        INSERT INTO daily_model_usage (day, provider, model, tokens)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(day, provider, model) DO UPDATE SET
            tokens = excluded.tokens,
            updated_at = CURRENT_TIMESTAMP
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        var succeeded = true
        for (model, tokens) in rows {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, day, -1, Self.transient)
            sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 3, model, -1, Self.transient)
            sqlite3_bind_int64(statement, 4, Int64(tokens))
            if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break }
        }
        sqlite3_finalize(statement)
        guard succeeded else { return false }

        let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
        let deleteSQL = """
        DELETE FROM daily_model_usage
        WHERE day = ? AND provider = ? AND model NOT IN (\(placeholders))
        """
        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(deleteStatement) }
        sqlite3_bind_text(deleteStatement, 1, day, -1, Self.transient)
        sqlite3_bind_text(deleteStatement, 2, provider, -1, Self.transient)
        for (index, model) in rows.keys.enumerated() {
            sqlite3_bind_text(deleteStatement, Int32(index + 3), model, -1, Self.transient)
        }
        return sqlite3_step(deleteStatement) == SQLITE_DONE
    }

    /// 数据落库后通知界面（统计页）刷新；backfill、5 分钟采集和集群同步都会触发
    static let dataDidChangeNotification = Notification.Name("ElinkUsageStoreDataDidChange")

    private static func notifyDataChanged() {
        NotificationCenter.default.post(name: dataDidChangeNotification, object: nil)
    }

    /// 时区重分桶后已迁移的 day key 整天清空：删除本地行，并把集群快照替换为
    /// 空集（revision +1），让对端也同步到清空结果。与 record 一样单事务完成。
    func clearLocalDay(day: String, provider: String) {
        let descriptor: ClusterSnapshotDescriptor? = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
            let sql = "DELETE FROM daily_model_usage WHERE day = ? AND provider = ?"
            var statement: OpaquePointer?
            var succeeded = false
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, day, -1, Self.transient)
                sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
                succeeded = sqlite3_step(statement) == SQLITE_DONE
            }
            sqlite3_finalize(statement)
            var result: ClusterSnapshotDescriptor?
            if succeeded {
                switch recordLocalSnapshotLocked(day: day, provider: provider, models: [:]) {
                case let .changed(value): result = value
                case .unchanged: break
                case .failed: succeeded = false
                }
            }
            return finishTransactionLocked(succeeded) ? result : nil
        }
        if let descriptor {
            onClusterUsageChange?([descriptor])
            Self.notifyDataChanged()
        }
    }

    /// 本地 daily 表按天/模型读取（不含集群数据），供时区重分桶计算“现存日志
    /// 解释不了的残差”；残差来自已删除的日志，是无法重建的唯一记录，必须保留
    func localDailyModelUsage(provider: String) -> [String: [String: Int]] {
        queue.sync { localDailyModelUsageLocked(provider: provider) ?? [:] }
    }

    private func localDailyModelUsageLocked(provider: String) -> DailyUsageTotals? {
        guard db != nil else { return nil }
        let sql = """
        SELECT day, model, tokens FROM daily_model_usage WHERE provider = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
        var totals: DailyUsageTotals = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return totals }
            guard result == SQLITE_ROW,
                  let day = sqlite3_column_text(statement, 0),
                  let model = sqlite3_column_text(statement, 1) else { return nil }
            totals[String(cString: day), default: [:]][String(cString: model)] =
                Int(sqlite3_column_int64(statement, 2))
        }
    }

    func usageBucketTimeZone() -> String? {
        queue.sync {
            let result = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            return result.succeeded ? result.value : nil
        }
    }

    func usageBucketHasLegacyUnknownData() -> Bool {
        queue.sync {
            let result = metadataValueLocked(Self.bucketLegacyUnknownMetadataKey)
            return result.succeeded && result.value == "1"
        }
    }

    /// 原子替换全部本地日用量、本机集群快照和分桶时区标记。
    /// expectedSource 是 CAS 条件：排队期间时区已被其他任务推进时，本任务不得覆盖新状态。
    func applyBucketMigration(expectedSource: String?, target: String,
                              oldExplained: UsageHistoryTotals?,
                              targetTotals: UsageHistoryTotals) -> UsageBucketMigrationResult {
        guard !target.isEmpty else { return .failed }
        var descriptors: [ClusterSnapshotDescriptor] = []
        let result = queue.sync { () -> UsageBucketMigrationResult in
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                return .failed
            }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded else {
                _ = finishTransactionLocked(false)
                return .failed
            }
            if marker.value == target {
                _ = finishTransactionLocked(false)
                return .alreadyCurrent
            }
            guard marker.value == expectedSource,
                  let storedClaude = localDailyModelUsageLocked(provider: "claude"),
                  let storedCodex = localDailyModelUsageLocked(provider: "codex") else {
                _ = finishTransactionLocked(false)
                return marker.value == expectedSource ? .failed : .sourceChanged
            }
            let stored = UsageHistoryTotals(claude: storedClaude, codex: storedCodex)
            let plan: UsageHistoryTotals
            if let oldExplained, expectedSource != nil {
                plan = UsageHistoryTotals(
                    claude: Self.knownRebucketPlan(
                        stored: stored.claude,
                        oldExplained: oldExplained.claude,
                        targetTotals: targetTotals.claude
                    ),
                    codex: Self.knownRebucketPlan(
                        stored: stored.codex,
                        oldExplained: oldExplained.codex,
                        targetTotals: targetTotals.codex
                    )
                )
            } else if oldExplained == nil, expectedSource == nil {
                plan = UsageHistoryTotals(
                    claude: Self.legacyRebucketPlan(
                        stored: stored.claude, targetTotals: targetTotals.claude
                    ),
                    codex: Self.legacyRebucketPlan(
                        stored: stored.codex, targetTotals: targetTotals.codex
                    )
                )
            } else {
                _ = finishTransactionLocked(false)
                return .failed
            }

            var succeeded = replaceLocalUsageLocked(
                plan: plan, stored: stored, descriptors: &descriptors
            )
            if succeeded {
                succeeded = setMetadataValueLocked(Self.bucketTimeZoneMetadataKey, value: target)
            }
            if succeeded, marker.value == nil {
                succeeded = setMetadataValueLocked(
                    Self.bucketLegacyUnknownMetadataKey,
                    value: stored.isEmpty ? "0" : "1"
                )
            }
            guard finishTransactionLocked(succeeded) else {
                descriptors.removeAll()
                return .failed
            }
            return .applied
        }
        if result == .applied {
            if !descriptors.isEmpty { onClusterUsageChange?(descriptors) }
            Self.notifyDataChanged()
        }
        return result
    }

    /// 同一时区的历史回填也要保留已删除日志形成的残差；直接 record 覆盖会在
    /// “当天仍有部分日志”时把残差清掉。这里同样以单事务替换全部本地历史。
    func mergeBackfillTotals(expectedTimeZone: String, totals: UsageHistoryTotals) -> Bool {
        var descriptors: [ClusterSnapshotDescriptor] = []
        let saved = queue.sync { () -> Bool in
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedTimeZone,
                  let storedClaude = localDailyModelUsageLocked(provider: "claude"),
                  let storedCodex = localDailyModelUsageLocked(provider: "codex") else {
                _ = finishTransactionLocked(false)
                return false
            }
            let stored = UsageHistoryTotals(claude: storedClaude, codex: storedCodex)
            let plan = UsageHistoryTotals(
                claude: Self.knownRebucketPlan(
                    stored: stored.claude,
                    oldExplained: totals.claude,
                    targetTotals: totals.claude
                ),
                codex: Self.knownRebucketPlan(
                    stored: stored.codex,
                    oldExplained: totals.codex,
                    targetTotals: totals.codex
                )
            )
            let succeeded = replaceLocalUsageLocked(
                plan: plan, stored: stored, descriptors: &descriptors
            )
            guard finishTransactionLocked(succeeded) else {
                descriptors.removeAll()
                return false
            }
            return true
        }
        if saved {
            if !descriptors.isEmpty { onClusterUsageChange?(descriptors) }
            Self.notifyDataChanged()
        }
        return saved
    }

    /// 已知旧时区时，只有 stored - oldExplained 才是无法由现存日志重建的历史残差。
    static func knownRebucketPlan(stored: DailyUsageTotals,
                                  oldExplained: DailyUsageTotals,
                                  targetTotals: DailyUsageTotals) -> DailyUsageTotals {
        var plan = positiveTotals(targetTotals)
        for (day, models) in stored {
            for (model, tokens) in models {
                let residue = max(0, tokens) - max(0, oldExplained[day]?[model] ?? 0)
                if residue > 0 {
                    plan[day, default: [:]][model, default: 0] += residue
                }
            }
        }
        return plan
    }

    /// 旧数据库没有分桶时区元数据，已删除日志的原日期无法恢复。这里按 provider/model
    /// 守恒总量：现存日志按目标时区重建，超出现存日志总量的部分稳定保留在原日期。
    static func legacyRebucketPlan(stored: DailyUsageTotals,
                                   targetTotals: DailyUsageTotals) -> DailyUsageTotals {
        var plan = positiveTotals(targetTotals)
        var models = Set<String>()
        stored.values.forEach { models.formUnion($0.keys) }
        targetTotals.values.forEach { models.formUnion($0.keys) }
        for model in models {
            let storedTotal = stored.values.reduce(0) { $0 + max(0, $1[model] ?? 0) }
            let targetTotal = targetTotals.values.reduce(0) { $0 + max(0, $1[model] ?? 0) }
            var remaining = max(0, storedTotal - targetTotal)
            guard remaining > 0 else { continue }
            for day in stored.keys.sorted() where remaining > 0 {
                let candidate = max(0, (stored[day]?[model] ?? 0)
                    - (targetTotals[day]?[model] ?? 0))
                let retained = min(candidate, remaining)
                if retained > 0 {
                    plan[day, default: [:]][model, default: 0] += retained
                    remaining -= retained
                }
            }
        }
        return plan
    }

    private static func positiveTotals(_ totals: DailyUsageTotals) -> DailyUsageTotals {
        var result: DailyUsageTotals = [:]
        for (day, models) in totals {
            for (model, tokens) in models where tokens > 0 {
                result[day, default: [:]][model] = tokens
            }
        }
        return result
    }

    private func replaceLocalUsageLocked(plan: UsageHistoryTotals,
                                         stored: UsageHistoryTotals,
                                         descriptors: inout [ClusterSnapshotDescriptor]) -> Bool {
        for provider in ["claude", "codex"] {
            let desired = plan.values(for: provider)
            let existing = stored.values(for: provider)
            for day in Set(desired.keys).union(existing.keys).sorted() {
                let rows = (desired[day] ?? [:]).filter { $0.value > 0 }
                let wroteDaily = rows.isEmpty
                    ? deleteDailyRowsLocked(day: day, provider: provider)
                    : replaceDailyRowsLocked(day: day, provider: provider, rows: rows)
                guard wroteDaily else { return false }
                switch recordLocalSnapshotLocked(day: day, provider: provider, models: rows) {
                case let .changed(value): descriptors.append(value)
                case .unchanged: break
                case .failed: return false
                }
            }
        }
        return true
    }

    /// 读单日模型行；失败返回 nil（与“空日”区分），供 preservingResidue 判定
    private func dayModelsLocked(day: String, provider: String) -> [String: Int]? {
        let sql = "SELECT model, tokens FROM daily_model_usage WHERE day = ? AND provider = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
        var models: [String: Int] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return models }
            guard result == SQLITE_ROW, let model = sqlite3_column_text(statement, 0) else {
                return nil
            }
            models[String(cString: model)] = Int(sqlite3_column_int64(statement, 1))
        }
    }

    private func deleteDailyRowsLocked(day: String, provider: String) -> Bool {
        let sql = "DELETE FROM daily_model_usage WHERE day = ? AND provider = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func metadataValueLocked(_ key: String) -> (succeeded: Bool, value: String?) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM usage_metadata WHERE key = ?", -1, &statement, nil
        ) == SQLITE_OK else { return (false, nil) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return (true, nil) }
        guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            return (false, nil)
        }
        return (true, String(cString: value))
    }

    private func setMetadataValueLocked(_ key: String, value: String) -> Bool {
        let sql = """
        INSERT INTO usage_metadata (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func usage(provider: String, since day: String) -> [DailyModelUsage] {
        if queue.sync(execute: { clusterNodeID != nil && clusterAggregationEnabled }) {
            return clusterUsage(provider: provider, since: day)
        }
        return queue.sync {
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
        // 没有任何窗口的响应不能清掉已持久化的缓存；过期数据由 cachedUsage 读取时丢弃
        guard !windows.isEmpty else { return }
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

    // MARK: - Cluster usage snapshots

    /// Enables cluster-aware storage for this process and imports existing local history once.
    func configureClusterStorage(nodeID: String, nodeName: String, aggregationEnabled: Bool) {
        queue.sync {
            clusterNodeID = nodeID
            clusterAggregationEnabled = aggregationEnabled
            _ = upsertNodeLocked(ClusterNodeRecord(
                nodeID: nodeID,
                name: nodeName,
                endpoint: nil,
                lastSeenAt: Date(),
                lastSyncAt: nil
            ))
            guard snapshotCountLocked(originNodeID: nodeID) == 0 else { return }
            let sql = """
            SELECT day, provider, model, tokens
            FROM daily_model_usage ORDER BY day, provider, model
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            var grouped: [String: [String: Int]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW,
                  let day = sqlite3_column_text(statement, 0),
                  let provider = sqlite3_column_text(statement, 1),
                  let model = sqlite3_column_text(statement, 2) {
                let key = "\(String(cString: day))\u{1f}\(String(cString: provider))"
                grouped[key, default: [:]][String(cString: model)] = Int(sqlite3_column_int64(statement, 3))
            }
            for (compound, models) in grouped {
                let parts = compound.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                _ = writeSnapshotLocked(ClusterUsageSnapshot(
                    key: ClusterSnapshotKey(originNodeID: nodeID, day: parts[0], provider: parts[1]),
                    revision: 1,
                    observedAt: Date(),
                    models: models
                ), requireNewer: true)
            }
        }
    }

    func setClusterAggregationEnabled(_ enabled: Bool) {
        queue.sync { clusterAggregationEnabled = enabled }
    }

    // The cluster identity and shared secret intentionally live in this local
    // SQLite database. The app never stores or reads them from macOS Keychain.
    func clusterCredentialsData() -> Data? {
        queue.sync {
            guard db != nil else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT payload FROM cluster_credentials WHERE singleton = 1",
                -1, &statement, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0 else { return nil }
            return Data(bytes: bytes, count: count)
        }
    }

    @discardableResult
    func saveClusterCredentialsData(_ data: Data) -> Bool {
        let saved = queue.sync {
            guard db != nil, !data.isEmpty else { return false }
            return upsertCredentialsLocked(data)
        }
        if saved { Self.protectDatabaseFiles(at: databasePath) }
        return saved
    }

    private func upsertCredentialsLocked(_ data: Data) -> Bool {
        let sql = """
        INSERT INTO cluster_credentials (singleton, payload, updated_at)
        VALUES (1, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET
          payload = excluded.payload,
          updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(data.count), Self.transient)
        }
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func clusterDataEpoch() -> Int {
        queue.sync { clusterDataEpochValue }
    }

    /// Removes data learned from a previous cluster while preserving this Mac's own history.
    func resetRemoteClusterData(localNodeID: String) {
        queue.sync {
            clusterDataEpochValue += 1
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
            _ = finishTransactionLocked(resetRemoteRowsLocked(localNodeID: localNodeID))
        }
    }

    /// 凭据与远端数据同库：切换集群时必须一个事务同时“换凭据 + 清旧数据”，
    /// 否则进程在两步之间退出，重启后会用新集群密钥广播旧集群快照
    func saveClusterCredentialsData(_ data: Data,
                                    resettingRemoteDataExceptNodeID localNodeID: String) -> Bool {
        let saved = queue.sync { () -> Bool in
            guard db != nil, !data.isEmpty,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            clusterDataEpochValue += 1
            let succeeded = upsertCredentialsLocked(data)
                && resetRemoteRowsLocked(localNodeID: localNodeID)
            return finishTransactionLocked(succeeded)
        }
        if saved { Self.protectDatabaseFiles(at: databasePath) }
        return saved
    }

    private func resetRemoteRowsLocked(localNodeID: String) -> Bool {
        var succeeded = true
        for table in ["cluster_model_usage", "cluster_usage_snapshots"] {
            var statement: OpaquePointer?
            let sql = "DELETE FROM \(table) WHERE origin_node_id != ?"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, localNodeID, -1, Self.transient)
                succeeded = sqlite3_step(statement) == SQLITE_DONE && succeeded
            } else { succeeded = false }
            sqlite3_finalize(statement)
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM cluster_nodes WHERE node_id != ?", -1,
                              &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, localNodeID, -1, Self.transient)
            succeeded = sqlite3_step(statement) == SQLITE_DONE && succeeded
        } else { succeeded = false }
        sqlite3_finalize(statement)
        return succeeded
    }

    func clusterUsage(provider: String, since day: String, nodeID: String? = nil) -> [DailyModelUsage] {
        queue.sync {
            guard db != nil else { return [] }
            var sql = """
            SELECT s.day, s.provider, m.model, m.tokens, s.origin_node_id
            FROM cluster_usage_snapshots s
            JOIN cluster_model_usage m
              ON m.origin_node_id = s.origin_node_id
             AND m.day = s.day AND m.provider = s.provider
            WHERE s.provider = ? AND s.day >= ?
            """
            if nodeID != nil { sql += " AND s.origin_node_id = ?" }
            sql += " ORDER BY s.day, m.model, s.origin_node_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            if let nodeID { sqlite3_bind_text(statement, 3, nodeID, -1, Self.transient) }
            var result: [DailyModelUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let dayText = sqlite3_column_text(statement, 0),
                  let providerText = sqlite3_column_text(statement, 1),
                  let modelText = sqlite3_column_text(statement, 2),
                  let nodeText = sqlite3_column_text(statement, 4) {
                result.append(DailyModelUsage(
                    day: String(cString: dayText),
                    provider: String(cString: providerText),
                    model: String(cString: modelText),
                    tokens: Int(sqlite3_column_int64(statement, 3)),
                    nodeID: String(cString: nodeText)
                ))
            }
            return result
        }
    }

    func clusterManifest() -> [ClusterSnapshotDescriptor] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT origin_node_id, day, provider, revision, content_hash
            FROM cluster_usage_snapshots ORDER BY origin_node_id, day, provider
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [ClusterSnapshotDescriptor] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let origin = sqlite3_column_text(statement, 0),
                  let day = sqlite3_column_text(statement, 1),
                  let provider = sqlite3_column_text(statement, 2),
                  let hash = sqlite3_column_text(statement, 4) {
                result.append(ClusterSnapshotDescriptor(
                    key: ClusterSnapshotKey(
                        originNodeID: String(cString: origin),
                        day: String(cString: day),
                        provider: String(cString: provider)
                    ),
                    revision: sqlite3_column_int64(statement, 3),
                    contentHash: String(cString: hash)
                ))
            }
            return result
        }
    }

    func clusterSnapshots(keys: [ClusterSnapshotKey]) -> [ClusterUsageSnapshot] {
        queue.sync { keys.compactMap(snapshotLocked) }
    }

    /// 返回 nil 表示 epoch 已过期或任一快照持久化失败；空数组表示请求有效但没有新数据
    @discardableResult
    func mergeClusterSnapshots(_ snapshots: [ClusterUsageSnapshot],
                               ifEpoch epoch: Int) -> [ClusterSnapshotDescriptor]? {
        let accepted = queue.sync { () -> [ClusterSnapshotDescriptor]? in
            // 纪元校验和写入同在串行队列内，与 resetRemoteClusterData 全序执行
            guard db != nil,
                  epoch == clusterDataEpochValue,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                return nil
            }
            var result: [ClusterSnapshotDescriptor] = []
            for snapshot in snapshots {
                // 本机 origin 的快照只能由本地 record() 产生，拒绝对端伪造覆盖
                guard snapshot.key.originNodeID != clusterNodeID,
                      ["claude", "codex"].contains(snapshot.key.provider),
                      snapshot.key.day.count == 10,
                      snapshot.models.count <= 100,
                      snapshot.models.allSatisfy({ !$0.key.isEmpty && $0.value >= 0 }) else { continue }
                if let existing = snapshotLocked(snapshot.key),
                   existing.revision >= snapshot.revision {
                    if existing.revision == snapshot.revision, existing.models != snapshot.models {
                        Log.warning(
                            "cluster snapshot conflict origin=\(snapshot.key.originNodeID) revision=\(snapshot.revision)",
                            category: "cluster"
                        )
                    }
                    continue
                }
                guard writeSnapshotBodyLocked(snapshot) else {
                    _ = finishTransactionLocked(false)
                    return nil
                }
                result.append(snapshot.descriptor)
            }
            guard finishTransactionLocked(true) else { return nil }
            return result
        }
        if let accepted, !accepted.isEmpty {
            onClusterUsageChange?(accepted)
            Self.notifyDataChanged()
        }
        return accepted
    }

    func clusterNodes() -> [ClusterNodeRecord] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT node_id, name, endpoint, last_seen_at, last_sync_at
            FROM cluster_nodes ORDER BY name, node_id
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [ClusterNodeRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let node = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) {
                let endpoint = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let lastSeen = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let lastSync = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                result.append(ClusterNodeRecord(
                    nodeID: String(cString: node),
                    name: String(cString: name),
                    endpoint: endpoint,
                    lastSeenAt: lastSeen,
                    lastSyncAt: lastSync
                ))
            }
            return result
        }
    }

    @discardableResult
    func upsertClusterNode(_ node: ClusterNodeRecord) -> Bool {
        queue.sync { upsertNodeLocked(node) }
    }

    @discardableResult
    func upsertRemoteClusterNode(_ node: ClusterNodeRecord, ifEpoch epoch: Int) -> Bool {
        queue.sync {
            guard epoch == clusterDataEpochValue else { return false }
            return upsertNodeLocked(node)
        }
    }

    /// “无变化”和“写入失败”必须区分：失败时调用方要回滚整个事务
    private enum SnapshotWrite {
        case changed(ClusterSnapshotDescriptor)
        case unchanged
        case failed
    }

    /// 本机快照写入体，不含队列同步和事务；调用方须在 queue 内、已开启事务时调用
    private func recordLocalSnapshotLocked(day: String, provider: String,
                                           models: [String: Int]) -> SnapshotWrite {
        guard let nodeID = clusterNodeID else { return .unchanged }
        let key = ClusterSnapshotKey(originNodeID: nodeID, day: day, provider: provider)
        let clean = models.filter { $0.value > 0 }
        let existing = snapshotLocked(key)
        guard existing?.models != clean else { return .unchanged }
        let snapshot = ClusterUsageSnapshot(
            key: key,
            revision: (existing?.revision ?? 0) + 1,
            observedAt: Date(),
            models: clean
        )
        return writeSnapshotBodyLocked(snapshot) ? .changed(snapshot.descriptor) : .failed
    }

    private func snapshotLocked(_ key: ClusterSnapshotKey) -> ClusterUsageSnapshot? {
        let header = """
        SELECT revision, observed_at FROM cluster_usage_snapshots
        WHERE origin_node_id = ? AND day = ? AND provider = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, header, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, key.originNodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, key.day, -1, Self.transient)
        sqlite3_bind_text(statement, 3, key.provider, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }
        let revision = sqlite3_column_int64(statement, 0)
        let observedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        sqlite3_finalize(statement)

        let rows = """
        SELECT model, tokens FROM cluster_model_usage
        WHERE origin_node_id = ? AND day = ? AND provider = ? ORDER BY model
        """
        guard sqlite3_prepare_v2(db, rows, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key.originNodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, key.day, -1, Self.transient)
        sqlite3_bind_text(statement, 3, key.provider, -1, Self.transient)
        var models: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let model = sqlite3_column_text(statement, 0) {
            models[String(cString: model)] = Int(sqlite3_column_int64(statement, 1))
        }
        return ClusterUsageSnapshot(
            key: key, revision: revision, observedAt: observedAt, models: models
        )
    }

    private func writeSnapshotLocked(_ snapshot: ClusterUsageSnapshot,
                                     requireNewer: Bool) -> SnapshotWrite {
        if requireNewer, let existing = snapshotLocked(snapshot.key), existing.revision >= snapshot.revision {
            if existing.revision == snapshot.revision, existing.models != snapshot.models {
                Log.warning("cluster snapshot conflict origin=\(snapshot.key.originNodeID) revision=\(snapshot.revision)",
                            category: "cluster")
            }
            return .unchanged
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return .failed }
        let succeeded = writeSnapshotBodyLocked(snapshot)
        guard finishTransactionLocked(succeeded) else { return .failed }
        return .changed(snapshot.descriptor)
    }

    /// 快照三张表的写入体，不含事务；调用方负责 BEGIN/COMMIT
    private func writeSnapshotBodyLocked(_ snapshot: ClusterUsageSnapshot) -> Bool {
        var succeeded = true
        let upsert = """
        INSERT INTO cluster_usage_snapshots
          (origin_node_id, day, provider, revision, observed_at, content_hash)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(origin_node_id, day, provider) DO UPDATE SET
          revision = excluded.revision,
          observed_at = excluded.observed_at,
          content_hash = excluded.content_hash
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, upsert, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, snapshot.key.originNodeID, -1, Self.transient)
            sqlite3_bind_text(statement, 2, snapshot.key.day, -1, Self.transient)
            sqlite3_bind_text(statement, 3, snapshot.key.provider, -1, Self.transient)
            sqlite3_bind_int64(statement, 4, snapshot.revision)
            sqlite3_bind_double(statement, 5, snapshot.observedAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 6, snapshot.descriptor.contentHash, -1, Self.transient)
            succeeded = sqlite3_step(statement) == SQLITE_DONE
        } else { succeeded = false }
        // finalize 后必须置 nil：失败路径会跳过后续 prepare，尾部的 finalize
        // 不能再碰这个已释放的指针（sqlite3_finalize(nil) 是安全 no-op）
        sqlite3_finalize(statement)
        statement = nil

        if succeeded {
            let delete = """
            DELETE FROM cluster_model_usage
            WHERE origin_node_id = ? AND day = ? AND provider = ?
            """
            if sqlite3_prepare_v2(db, delete, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, snapshot.key.originNodeID, -1, Self.transient)
                sqlite3_bind_text(statement, 2, snapshot.key.day, -1, Self.transient)
                sqlite3_bind_text(statement, 3, snapshot.key.provider, -1, Self.transient)
                succeeded = sqlite3_step(statement) == SQLITE_DONE
            } else { succeeded = false }
            sqlite3_finalize(statement)
            statement = nil
        }

        let insert = """
        INSERT INTO cluster_model_usage (origin_node_id, day, provider, model, tokens)
        VALUES (?, ?, ?, ?, ?)
        """
        if succeeded, sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
            for (model, tokens) in snapshot.models where tokens > 0 {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, snapshot.key.originNodeID, -1, Self.transient)
                sqlite3_bind_text(statement, 2, snapshot.key.day, -1, Self.transient)
                sqlite3_bind_text(statement, 3, snapshot.key.provider, -1, Self.transient)
                sqlite3_bind_text(statement, 4, model, -1, Self.transient)
                sqlite3_bind_int64(statement, 5, Int64(tokens))
                if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break }
            }
        } else if succeeded { succeeded = false }
        sqlite3_finalize(statement)
        return succeeded
    }

    private func snapshotCountLocked(originNodeID: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM cluster_usage_snapshots WHERE origin_node_id = ?",
            -1, &statement, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, originNodeID, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func upsertNodeLocked(_ node: ClusterNodeRecord) -> Bool {
        let sql = """
        INSERT INTO cluster_nodes (node_id, name, endpoint, last_seen_at, last_sync_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
          name = excluded.name,
          endpoint = COALESCE(excluded.endpoint, cluster_nodes.endpoint),
          last_seen_at = CASE
            WHEN excluded.last_seen_at > COALESCE(cluster_nodes.last_seen_at, 0)
            THEN excluded.last_seen_at ELSE cluster_nodes.last_seen_at END,
          last_sync_at = CASE
            WHEN excluded.last_sync_at > COALESCE(cluster_nodes.last_sync_at, 0)
            THEN excluded.last_sync_at ELSE cluster_nodes.last_sync_at END
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, node.nodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, node.name, -1, Self.transient)
        if let endpoint = node.endpoint { sqlite3_bind_text(statement, 3, endpoint, -1, Self.transient) }
        else { sqlite3_bind_null(statement, 3) }
        if let seen = node.lastSeenAt { sqlite3_bind_double(statement, 4, seen.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 4) }
        if let sync = node.lastSyncAt { sqlite3_bind_double(statement, 5, sync.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 5) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func createClusterTables(in db: OpaquePointer?) {
        let sql = """
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
        CREATE TABLE IF NOT EXISTS cluster_credentials (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          payload BLOB NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cluster_usage_provider_day
          ON cluster_usage_snapshots(provider, day);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.error("cluster usage tables create failed", category: "storage")
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
            Log.error("usage db timestamp migration failed", category: "storage")
        }
    }

    private static func protectDatabaseFiles(at path: String) {
        guard path != ":memory:" else { return }
        for candidate in [path, path + "-wal", path + "-shm"]
            where FileManager.default.fileExists(atPath: candidate) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: candidate
            )
        }
    }
}
