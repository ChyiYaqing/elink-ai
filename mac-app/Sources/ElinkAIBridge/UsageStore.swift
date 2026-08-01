import Foundation
import SQLite3

struct DailyModelUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String // "claude" / "codex"
    var model: String
    var tokens: Int
    var nodeID: String? = nil
}

struct HourlyModelUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var hour: Int        // 0..23
    var provider: String
    var model: String
    var tokens: Int
    /// 产生这一行的节点。nil = 本机且未组集群，与 `DailyModelUsage` 同一套约定。
    var nodeID: String?
}

struct DailyCategoryUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String
    var category: String // input / output / cache_read / cache_write / reasoning
    var tokens: Int
}

/// 模型与分类的交叉用量。算钱必须同时知道这两维：单价既随模型变（Fable 是
/// Sonnet 的三倍多），也随分类变（输出是输入的五倍、缓存读只有十分之一），
/// 只按其中一维聚合的 `DailyModelUsage` / `DailyCategoryUsage` 都还原不出金额。
struct ModelCategoryUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String
    var model: String
    var category: String
    var tokens: Int
}

/// 一个五分钟桶。`rttAvgUs` 为 nil 表示这五分钟一次都没通——必须与「0ms」区分，
/// 否则图上会画出一条根本不存在的零延迟线。
struct MeshBucketPoint: Equatable {
    var bucketAt: Date
    var samples: Int
    var okSamples: Int
    var rttMinUs: Int?
    var rttMaxUs: Int?
    var rttAvgUs: Int?

    // 减法写成先比后减：这两个数可能来自 lighthouse 的明文文档，越界相减在 Swift 里
    // 是 trap。解析层已经限过取值域，这里不再依赖它。
    var lostSamples: Int { okSamples >= samples ? 0 : samples - okSamples }
    var fullyLost: Bool { samples > 0 && okSamples == 0 }
}

/// 某节点在一个窗口内所有桶的合并结果。
struct MeshAggregate: Equatable {
    var samples = 0
    var okSamples = 0
    var rttMinUs: Int?
    var rttMaxUs: Int?
    var rttSumUs = 0
}

enum LinkEventKind: String {
    /// 外部 IP 变化：NAT 映射已清空，随后通常伴随一轮端口重新抢占
    case wanRebind = "wan_rebind"
    /// 出口保留了源端口，本机因此位于端口争抢池里——这不是“正常”，是风险条件
    case portPreserved = "port_preserved"
    /// 出口或本机 TUN 代理重写了源端口，本机不参与争抢
    case portRewritten = "port_rewritten"
    /// 所有 STUN 服务器都不可达，端口判据暂时失效
    case stunUnavailable = "stun_unavailable"
}

struct LinkEvent: Equatable {
    var occurredAt: Date
    var nodeID: String
    var kind: LinkEventKind
    var detail: String?  // 含内网地址，只在本机 UI 呈现，不进 /v1/status
}

typealias DailyUsageTotals = [String: [String: Int]]

/// day -> model -> category -> tokens
typealias DayModelCategories = [String: [String: [String: Int]]]

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
    private static let parserVersionMetadataKey = "usage_parser_version"
    private static let lastExternalEndpointKey = "link_last_external_endpoint"
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
            let createHourly = """
            CREATE TABLE IF NOT EXISTS hourly_model_usage (
                day TEXT NOT NULL,
                hour INTEGER NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                PRIMARY KEY (day, hour, provider, model)
            )
            """
            if sqlite3_exec(db, createHourly, nil, nil, nil) != SQLITE_OK {
                Log.error("hourly usage table create failed", category: "storage")
            }
            let createCategory = """
            CREATE TABLE IF NOT EXISTS daily_category_usage (
                day TEXT NOT NULL,
                provider TEXT NOT NULL,
                category TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                PRIMARY KEY (day, provider, category)
            )
            """
            if sqlite3_exec(db, createCategory, nil, nil, nil) != SQLITE_OK {
                Log.error("category usage table create failed", category: "storage")
            }
            // 金额只能从这张交叉表算：单价同时取决于模型和分类，上面两张单维表都还原不出来
            let createModelCategory = """
            CREATE TABLE IF NOT EXISTS daily_model_category_usage (
                day TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                category TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                PRIMARY KEY (day, provider, model, category)
            )
            """
            if sqlite3_exec(db, createModelCategory, nil, nil, nil) != SQLITE_OK {
                Log.error("model category usage table create failed", category: "storage")
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
            Self.createLinkTables(in: db)
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

    /// 覆盖写入某天某 provider 的小时分布（仅本机，不参与集群同步/残差/迁移）。
    /// 空集只会来自暂时读不到日志的场景，直接忽略，避免清掉已有小时数据。
    func recordHourly(day: String, provider: String, hours: [Int: [String: Int]],
                      expectedBucketTimeZone: String?) {
        var rows: [HourlyModelUsage] = []
        for (hour, models) in hours {
            for (model, tokens) in models where tokens > 0 {
                rows.append(HourlyModelUsage(
                    day: day, hour: hour, provider: provider, model: model, tokens: tokens
                ))
            }
        }
        guard !rows.isEmpty else { return }
        let changed: Bool = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedBucketTimeZone else {
                _ = finishTransactionLocked(false)
                return false
            }
            // 无变化时回滚且不发通知，避免统计页随 5 分钟采集反复重载
            if let existing = hourlyRowsLocked(day: day, provider: provider),
               Set(existing.map { "\($0.hour)|\($0.model)|\($0.tokens)" })
                   == Set(rows.map { "\($0.hour)|\($0.model)|\($0.tokens)" }) {
                _ = finishTransactionLocked(false)
                return false
            }
            var succeeded = false
            var deleteStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM hourly_model_usage WHERE day = ? AND provider = ?",
                                  -1, &deleteStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStatement, 1, day, -1, Self.transient)
                sqlite3_bind_text(deleteStatement, 2, provider, -1, Self.transient)
                succeeded = sqlite3_step(deleteStatement) == SQLITE_DONE
            }
            sqlite3_finalize(deleteStatement)
            if succeeded {
                let insert = """
                INSERT INTO hourly_model_usage (day, hour, provider, model, tokens)
                VALUES (?, ?, ?, ?, ?)
                """
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
                    for row in rows {
                        sqlite3_reset(statement)
                        sqlite3_bind_text(statement, 1, row.day, -1, Self.transient)
                        sqlite3_bind_int64(statement, 2, Int64(row.hour))
                        sqlite3_bind_text(statement, 3, row.provider, -1, Self.transient)
                        sqlite3_bind_text(statement, 4, row.model, -1, Self.transient)
                        sqlite3_bind_int64(statement, 5, Int64(row.tokens))
                        if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break }
                    }
                } else {
                    succeeded = false
                }
                sqlite3_finalize(statement)
            }
            // 组了集群就同时写一份到集群表：读路径统一走那张表，本机缺席会让「今日」
            // 少算自己。快照按需从这张表取小时数据，对端下次拉取就能拿到。
            if succeeded, let nodeID = clusterNodeID {
                succeeded = replaceClusterHourlyLocked(
                    nodeID: nodeID, day: day, provider: provider, hours: Self.hourBuckets(rows)
                )
            }
            return finishTransactionLocked(succeeded)
        }
        if changed { Self.notifyDataChanged() }
    }

    /// 小时行 → `"0"…"23"` → 模型 → token。协议里用字符串键，JSON 字典别无选择。
    static func hourBuckets(_ rows: [HourlyModelUsage]) -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for row in rows where row.tokens > 0 {
            result[String(row.hour), default: [:]][row.model, default: 0] += row.tokens
        }
        return result
    }

    /// 覆盖某节点某天某 provider 的小时行。须在事务与 queue 内调用。
    private func replaceClusterHourlyLocked(nodeID: String, day: String, provider: String,
                                            hours: [String: [String: Int]]) -> Bool {
        var statement: OpaquePointer?
        let delete = """
        DELETE FROM cluster_hourly_usage
        WHERE origin_node_id = ? AND day = ? AND provider = ?
        """
        guard sqlite3_prepare_v2(db, delete, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, nodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, day, -1, Self.transient)
        sqlite3_bind_text(statement, 3, provider, -1, Self.transient)
        var succeeded = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        statement = nil
        guard succeeded else { return false }

        let insert = """
        INSERT INTO cluster_hourly_usage
          (origin_node_id, day, hour, provider, model, tokens)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        for (hour, models) in hours {
            guard let hourValue = Int(hour), (0...23).contains(hourValue) else { continue }
            for (model, tokens) in models where tokens > 0 {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, nodeID, -1, Self.transient)
                sqlite3_bind_text(statement, 2, day, -1, Self.transient)
                sqlite3_bind_int64(statement, 3, Int64(hourValue))
                sqlite3_bind_text(statement, 4, provider, -1, Self.transient)
                sqlite3_bind_text(statement, 5, model, -1, Self.transient)
                sqlite3_bind_int64(statement, 6, Int64(tokens))
                if sqlite3_step(statement) != SQLITE_DONE {
                    succeeded = false
                    break
                }
            }
            if !succeeded { break }
        }
        return succeeded
    }

    /// 读单日小时行；失败返回 nil（与“空日”区分）。须在 queue 内调用
    private func hourlyRowsLocked(day: String, provider: String) -> [HourlyModelUsage]? {
        let sql = """
        SELECT hour, model, tokens FROM hourly_model_usage
        WHERE day = ? AND provider = ? ORDER BY hour, model
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
        var rows: [HourlyModelUsage] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, let model = sqlite3_column_text(statement, 1) else {
                return nil
            }
            rows.append(HourlyModelUsage(
                day: day,
                hour: Int(sqlite3_column_int64(statement, 0)),
                provider: provider,
                model: String(cString: model),
                tokens: Int(sqlite3_column_int64(statement, 2))
            ))
        }
    }

    /// 小时数据仅本机记录，不走集群聚合分支
    /// 组了集群就走集群表：本机自己的小时行也在里面（`recordHourly` 会同时写一份），
    /// 与 `usage(provider:since:)` 的做法一致。
    ///
    /// 唯一的例外是本机那一份还没写进去的时候——刚升级完，集群表里还没有今天的自己，
    /// 要等下一轮采集。这时用本地表补上，否则「今日」会在几分钟里少掉本机。补的是
    /// 「集群表里没有本机行」这一种情况，不会和已有的本机行重复计算。
    func hourlyUsage(provider: String, day: String) -> [HourlyModelUsage] {
        let node: String? = queue.sync {
            clusterAggregationEnabled ? clusterNodeID : nil
        }
        guard let node else {
            return queue.sync {
                guard db != nil else { return [] }
                return hourlyRowsLocked(day: day, provider: provider) ?? []
            }
        }
        let rows = clusterHourlyUsage(provider: provider, day: day)
        guard !rows.contains(where: { $0.nodeID == node }) else { return rows }
        let local = queue.sync {
            db == nil ? [] : (hourlyRowsLocked(day: day, provider: provider) ?? [])
        }
        return rows + local.map {
            HourlyModelUsage(day: $0.day, hour: $0.hour, provider: $0.provider,
                             model: $0.model, tokens: $0.tokens, nodeID: node)
        }
    }

    func clusterHourlyUsage(provider: String, day: String) -> [HourlyModelUsage] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT hour, model, tokens, origin_node_id FROM cluster_hourly_usage
            WHERE provider = ? AND day = ? ORDER BY hour, model, origin_node_id
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            var result: [HourlyModelUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let model = sqlite3_column_text(statement, 1),
                  let node = sqlite3_column_text(statement, 3) {
                result.append(HourlyModelUsage(
                    day: day, hour: Int(sqlite3_column_int64(statement, 0)),
                    provider: provider, model: String(cString: model),
                    tokens: Int(sqlite3_column_int64(statement, 2)),
                    nodeID: String(cString: node)
                ))
            }
            return result
        }
    }

    /// 覆盖写入某天某 provider 的 token 分类用量（仅本机，不参与集群同步/残差/迁移）。
    /// 空集只会来自暂时读不到日志的场景，直接忽略，避免清掉已有分类数据。
    func recordCategories(day: String, provider: String, categories: [String: Int],
                          expectedBucketTimeZone: String?) {
        let rows = categories.filter { $0.value > 0 }
        guard !rows.isEmpty else { return }
        let changed: Bool = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedBucketTimeZone else {
                _ = finishTransactionLocked(false)
                return false
            }
            // 无变化时回滚且不发通知，避免统计页随 5 分钟采集反复重载
            if let existing = categoryRowsLocked(day: day, provider: provider), existing == rows {
                _ = finishTransactionLocked(false)
                return false
            }
            var succeeded = false
            var deleteStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM daily_category_usage WHERE day = ? AND provider = ?",
                                  -1, &deleteStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStatement, 1, day, -1, Self.transient)
                sqlite3_bind_text(deleteStatement, 2, provider, -1, Self.transient)
                succeeded = sqlite3_step(deleteStatement) == SQLITE_DONE
            }
            sqlite3_finalize(deleteStatement)
            if succeeded {
                let insert = """
                INSERT INTO daily_category_usage (day, provider, category, tokens)
                VALUES (?, ?, ?, ?)
                """
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
                    for (category, tokens) in rows {
                        sqlite3_reset(statement)
                        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
                        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
                        sqlite3_bind_text(statement, 3, category, -1, Self.transient)
                        sqlite3_bind_int64(statement, 4, Int64(tokens))
                        if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break }
                    }
                } else {
                    succeeded = false
                }
                sqlite3_finalize(statement)
            }
            return finishTransactionLocked(succeeded)
        }
        if changed { Self.notifyDataChanged() }
    }

    /// 读单日分类行；失败返回 nil（与“空日”区分）。须在 queue 内调用
    private func categoryRowsLocked(day: String, provider: String) -> [String: Int]? {
        let sql = """
        SELECT category, tokens FROM daily_category_usage WHERE day = ? AND provider = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
        var rows: [String: Int] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, let category = sqlite3_column_text(statement, 0) else {
                return nil
            }
            rows[String(cString: category)] = Int(sqlite3_column_int64(statement, 1))
        }
    }

    /// 覆盖写入某天某 provider 的 模型×分类 用量。语义与 `recordCategories` 一致：
    /// 空集当作“这次没读到日志”而不是“这天没用量”，直接忽略以免清掉已有数据。
    func recordModelCategories(day: String, provider: String,
                               usage: [String: [String: Int]],
                               expectedBucketTimeZone: String?) {
        var rows: [String: [String: Int]] = [:]
        for (model, categories) in usage {
            let positive = categories.filter { $0.value > 0 }
            if !positive.isEmpty { rows[model] = positive }
        }
        guard !rows.isEmpty else { return }
        let changed: Bool = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedBucketTimeZone else {
                _ = finishTransactionLocked(false)
                return false
            }
            if let existing = modelCategoryRowsLocked(day: day, provider: provider), existing == rows {
                _ = finishTransactionLocked(false)
                return false
            }
            var succeeded = false
            var deleteStatement: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "DELETE FROM daily_model_category_usage WHERE day = ? AND provider = ?",
                -1, &deleteStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStatement, 1, day, -1, Self.transient)
                sqlite3_bind_text(deleteStatement, 2, provider, -1, Self.transient)
                succeeded = sqlite3_step(deleteStatement) == SQLITE_DONE
            }
            sqlite3_finalize(deleteStatement)
            if succeeded {
                let insert = """
                INSERT INTO daily_model_category_usage (day, provider, model, category, tokens)
                VALUES (?, ?, ?, ?, ?)
                """
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
                    outer: for (model, categories) in rows {
                        for (category, tokens) in categories {
                            sqlite3_reset(statement)
                            sqlite3_bind_text(statement, 1, day, -1, Self.transient)
                            sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
                            sqlite3_bind_text(statement, 3, model, -1, Self.transient)
                            sqlite3_bind_text(statement, 4, category, -1, Self.transient)
                            sqlite3_bind_int64(statement, 5, Int64(tokens))
                            if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break outer }
                        }
                    }
                } else {
                    succeeded = false
                }
                sqlite3_finalize(statement)
            }
            // 与小时数据同理：组了集群就同时写一份到集群表，快照按需从那里取，
            // 对端下次拉取就能拿到本机的分类分布并折算出金额。
            if succeeded, let nodeID = clusterNodeID {
                succeeded = replaceClusterCategoriesLocked(
                    nodeID: nodeID, day: day, provider: provider, categories: rows
                )
            }
            return finishTransactionLocked(succeeded)
        }
        if changed { Self.notifyDataChanged() }
    }

    /// 回填多天的 模型×分类 用量（历史重扫的产物）。
    ///
    /// 这张表是纯派生数据：它只是把日志里已有的数字换一种维度堆叠，没有
    /// `daily_model_usage` 那种「日志已删、用量要靠残差留住」的语义，所以直接按
    /// 扫到的结果覆盖即可，不掺进 `mergeBackfillTotals` 的残差与精确重建逻辑。
    ///
    /// 缺了它，统计页的周/月/年金额只会算到「这张表建好之后」的那几天，
    /// 而 token 总量是回填过的——两个数并排放着，金额会莫名其妙地小一截。
    @discardableResult
    func backfillModelCategories(expectedTimeZone: String?,
                                 usage: [String: DayModelCategories]) -> Bool {
        let changed: Bool = queue.sync {
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
            let marker = metadataValueLocked(Self.bucketTimeZoneMetadataKey)
            guard marker.succeeded, marker.value == expectedTimeZone else {
                _ = finishTransactionLocked(false)
                return false
            }
            var succeeded = true
            for (provider, days) in usage where ["claude", "codex"].contains(provider) {
                guard succeeded else { break }
                // 整个 provider 一次性重建：扫描覆盖的是全部历史，留下旧行只会
                // 让改过归属的那些天既算新的又算旧的。
                var deleteStatement: OpaquePointer?
                if sqlite3_prepare_v2(
                    db, "DELETE FROM daily_model_category_usage WHERE provider = ?",
                    -1, &deleteStatement, nil) == SQLITE_OK {
                    sqlite3_bind_text(deleteStatement, 1, provider, -1, Self.transient)
                    succeeded = sqlite3_step(deleteStatement) == SQLITE_DONE
                } else {
                    succeeded = false
                }
                sqlite3_finalize(deleteStatement)
                guard succeeded else { break }

                let insert = """
                INSERT INTO daily_model_category_usage
                  (day, provider, model, category, tokens)
                VALUES (?, ?, ?, ?, ?)
                """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else {
                    succeeded = false
                    break
                }
                outer: for (day, models) in days {
                    for (model, categories) in models {
                        for (category, tokens) in categories where tokens > 0 {
                            sqlite3_reset(statement)
                            sqlite3_bind_text(statement, 1, day, -1, Self.transient)
                            sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
                            sqlite3_bind_text(statement, 3, model, -1, Self.transient)
                            sqlite3_bind_text(statement, 4, category, -1, Self.transient)
                            sqlite3_bind_int64(statement, 5, Int64(tokens))
                            if sqlite3_step(statement) != SQLITE_DONE {
                                succeeded = false
                                break outer
                            }
                        }
                    }
                }
                sqlite3_finalize(statement)
            }
            return finishTransactionLocked(succeeded)
        }
        if changed { Self.notifyDataChanged() }
        return changed
    }

    /// 读单日 模型×分类 行；失败返回 nil（与“空日”区分）。须在 queue 内调用
    private func modelCategoryRowsLocked(day: String,
                                         provider: String) -> [String: [String: Int]]? {
        let sql = """
        SELECT model, category, tokens FROM daily_model_category_usage
        WHERE day = ? AND provider = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, day, -1, Self.transient)
        sqlite3_bind_text(statement, 2, provider, -1, Self.transient)
        var rows: [String: [String: Int]] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW,
                  let model = sqlite3_column_text(statement, 0),
                  let category = sqlite3_column_text(statement, 1) else { return nil }
            rows[String(cString: model), default: [:]][String(cString: category)] =
                Int(sqlite3_column_int64(statement, 2))
        }
    }

    /// 金额折算的数据源。口径必须与 `usage(provider:since:)` 一致：组了集群就读
    /// 全节点，否则金额是本机的、上方的 token 数是全集群的，两个数并排放着却在
    /// 讲不同的机器。
    func modelCategoryUsage(provider: String, since day: String) -> [ModelCategoryUsage] {
        if queue.sync(execute: { clusterNodeID != nil && clusterAggregationEnabled }) {
            return clusterModelCategoryUsage(provider: provider, since: day)
        }
        return localModelCategoryUsage(provider: provider, since: day)
    }

    /// 集群口径：各节点随快照送来的分类分布。没送分类的节点（老版本）在这里
    /// 没有行，其用量因此不计入金额——调用方要把这个缺口说出来。
    func clusterModelCategoryUsage(provider: String, since day: String,
                                   nodeID: String? = nil) -> [ModelCategoryUsage] {
        queue.sync {
            guard db != nil else { return [] }
            var sql = """
            SELECT s.day, c.model, c.category, c.tokens
            FROM cluster_usage_snapshots s
            JOIN cluster_model_category_usage c
              ON c.origin_node_id = s.origin_node_id
             AND c.day = s.day AND c.provider = s.provider
            WHERE s.provider = ? AND s.day >= ?
            """
            if nodeID != nil { sql += " AND s.origin_node_id = ?" }
            sql += " ORDER BY s.day, c.model, c.category"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            if let nodeID { sqlite3_bind_text(statement, 3, nodeID, -1, Self.transient) }
            var result: [ModelCategoryUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let dayText = sqlite3_column_text(statement, 0),
                  let modelText = sqlite3_column_text(statement, 1),
                  let categoryText = sqlite3_column_text(statement, 2) {
                result.append(ModelCategoryUsage(
                    day: String(cString: dayText),
                    provider: provider,
                    model: String(cString: modelText),
                    category: String(cString: categoryText),
                    tokens: Int(sqlite3_column_int64(statement, 3))
                ))
            }
            return result
        }
    }

    private func localModelCategoryUsage(provider: String, since day: String) -> [ModelCategoryUsage] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT day, model, category, tokens FROM daily_model_category_usage
            WHERE provider = ? AND day >= ? ORDER BY day, model, category
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            var result: [ModelCategoryUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let dayText = sqlite3_column_text(statement, 0),
                      let modelText = sqlite3_column_text(statement, 1),
                      let categoryText = sqlite3_column_text(statement, 2) else { continue }
                result.append(ModelCategoryUsage(
                    day: String(cString: dayText),
                    provider: provider,
                    model: String(cString: modelText),
                    category: String(cString: categoryText),
                    tokens: Int(sqlite3_column_int64(statement, 3))
                ))
            }
            return result
        }
    }

    /// 分类数据仅本机记录，不走集群聚合分支
    func categoryUsage(provider: String, since day: String) -> [DailyCategoryUsage] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT day, category, tokens FROM daily_category_usage
            WHERE provider = ? AND day >= ? ORDER BY day, category
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, provider, -1, Self.transient)
            sqlite3_bind_text(statement, 2, day, -1, Self.transient)
            var result: [DailyCategoryUsage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let dayText = sqlite3_column_text(statement, 0),
                      let categoryText = sqlite3_column_text(statement, 1) else { continue }
                result.append(DailyCategoryUsage(
                    day: String(cString: dayText),
                    provider: provider,
                    category: String(cString: categoryText),
                    tokens: Int(sqlite3_column_int64(statement, 2))
                ))
            }
            return result
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

    /// 最近一次成功精确重建时的解析器版本；与当前版本不一致说明库里可能
    /// 残留旧解析器的错误归因（如 subagent 前置事件被记成 unknown）
    func usageParserVersion() -> String? {
        queue.sync {
            let result = metadataValueLocked(Self.parserVersionMetadataKey)
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
    /// exact 供解析器版本升级后的一次性清洗：现存日志覆盖的日期按重算值精确
    /// 替换（丢弃残差，去掉旧解析器的错误归因），日志不覆盖的日期原样保留；
    /// recordingParserVersion 在同一事务里登记清洗完成的版本。
    func mergeBackfillTotals(expectedTimeZone: String, totals: UsageHistoryTotals,
                             exact: Bool = false,
                             recordingParserVersion: String? = nil) -> Bool {
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
            let plan: UsageHistoryTotals
            if exact {
                plan = UsageHistoryTotals(
                    claude: Self.exactRebuildPlan(stored: stored.claude, targetTotals: totals.claude),
                    codex: Self.exactRebuildPlan(stored: stored.codex, targetTotals: totals.codex)
                )
            } else {
                plan = UsageHistoryTotals(
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
            }
            var succeeded = replaceLocalUsageLocked(
                plan: plan, stored: stored, descriptors: &descriptors
            )
            if succeeded, let recordingParserVersion {
                succeeded = setMetadataValueLocked(
                    Self.parserVersionMetadataKey, value: recordingParserVersion
                )
            }
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

    /// 解析器升级后的精确重建：重算覆盖到的日期用重算值整日替换，
    /// 现存日志完全不覆盖的日期无从重算，原样保留
    static func exactRebuildPlan(stored: DailyUsageTotals,
                                 targetTotals: DailyUsageTotals) -> DailyUsageTotals {
        var plan = positiveTotals(targetTotals)
        for (day, models) in stored where targetTotals[day] == nil {
            for (model, tokens) in models where tokens > 0 {
                plan[day, default: [:]][model] = tokens
            }
        }
        return plan
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
            seedClusterHourlyLocked(nodeID: nodeID)
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

    /// 把本地小时行补写进集群表。须在 queue 内调用。
    ///
    /// 集群表里的这一份是本地表的派生缓存，平时由 `recordHourly` 顺带维护。但那条路
    /// 上有一道「数据没变化就回滚」的守卫——它挡的是 5 分钟一次的采集把统计页刷得
    /// 乱跳——于是刚升级完、当天又不再产生用量的机器，它今天已有的小时分布永远不会
    /// 被镜像出去：别人看得到它的天级用量，却看不到它今日的分布。
    ///
    /// 组集群的这一刻正好覆盖两种时机：升级重启，以及第一次配对。整张本地表也就
    /// 几十行，重算一遍比判断「哪几天需要补」更省事，也更难写错。
    private func seedClusterHourlyLocked(nodeID: String) {
        let sql = """
        SELECT day, hour, provider, model, tokens FROM hourly_model_usage
        ORDER BY day, provider, hour, model
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        var grouped: [String: [String: [String: Int]]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let day = sqlite3_column_text(statement, 0),
              let provider = sqlite3_column_text(statement, 2),
              let model = sqlite3_column_text(statement, 3) {
            let key = "\(String(cString: day))\u{1f}\(String(cString: provider))"
            let hour = String(sqlite3_column_int64(statement, 1))
            grouped[key, default: [:]][hour, default: [:]][String(cString: model)]
                = Int(sqlite3_column_int64(statement, 4))
        }
        sqlite3_finalize(statement)
        guard !grouped.isEmpty,
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var succeeded = true
        for (compound, hours) in grouped {
            let parts = compound.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            succeeded = replaceClusterHourlyLocked(
                nodeID: nodeID, day: parts[0], provider: parts[1], hours: hours
            )
            if !succeeded { break }
        }
        _ = finishTransactionLocked(succeeded)
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

    /// Removes data learned from a previous cluster while preserving this host's own history.
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
        sqlite3_finalize(statement)
        statement = nil

        // 小时分布随快照一起发出去，对端的「今日」才拆得出设备
        let hourRows = """
        SELECT hour, model, tokens FROM cluster_hourly_usage
        WHERE origin_node_id = ? AND day = ? AND provider = ? ORDER BY hour, model
        """
        var hours: [String: [String: Int]] = [:]
        if sqlite3_prepare_v2(db, hourRows, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key.originNodeID, -1, Self.transient)
            sqlite3_bind_text(statement, 2, key.day, -1, Self.transient)
            sqlite3_bind_text(statement, 3, key.provider, -1, Self.transient)
            while sqlite3_step(statement) == SQLITE_ROW,
                  let model = sqlite3_column_text(statement, 1) {
                hours[String(sqlite3_column_int64(statement, 0)), default: [:]][String(cString: model)]
                    = Int(sqlite3_column_int64(statement, 2))
            }
        }
        sqlite3_finalize(statement)
        statement = nil

        // 分类分布同样随快照发出，对端才折算得出这台机器的金额
        let categoryRows = """
        SELECT model, category, tokens FROM cluster_model_category_usage
        WHERE origin_node_id = ? AND day = ? AND provider = ? ORDER BY model, category
        """
        var categories: [String: [String: Int]] = [:]
        if sqlite3_prepare_v2(db, categoryRows, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key.originNodeID, -1, Self.transient)
            sqlite3_bind_text(statement, 2, key.day, -1, Self.transient)
            sqlite3_bind_text(statement, 3, key.provider, -1, Self.transient)
            while sqlite3_step(statement) == SQLITE_ROW,
                  let model = sqlite3_column_text(statement, 0),
                  let category = sqlite3_column_text(statement, 1) {
                categories[String(cString: model), default: [:]][String(cString: category)]
                    = Int(sqlite3_column_int64(statement, 2))
            }
        }
        sqlite3_finalize(statement)
        statement = nil
        return ClusterUsageSnapshot(
            key: key, revision: revision, observedAt: observedAt, models: models,
            hours: hours, categories: categories
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
        statement = nil

        // hours 为 nil 表示对端没提供（老版本节点），保留已有的那份；空字典才是
        // 「这天确实没有小时数据」，覆盖成空。把两者混为一谈，一次来自旧节点的
        // 同步就会把已经拿到的分布抹掉。
        if succeeded, let hours = snapshot.hours {
            succeeded = replaceClusterHourlyLocked(
                nodeID: snapshot.key.originNodeID, day: snapshot.key.day,
                provider: snapshot.key.provider, hours: hours
            )
        }
        // 与 hours 同理：nil 是「对端没提供」，保留旧值；空字典才是「确实没有」。
        if succeeded, let categories = snapshot.categories {
            succeeded = replaceClusterCategoriesLocked(
                nodeID: snapshot.key.originNodeID, day: snapshot.key.day,
                provider: snapshot.key.provider, categories: categories
            )
        }
        return succeeded
    }

    private func replaceClusterCategoriesLocked(
        nodeID: String, day: String, provider: String,
        categories: [String: [String: Int]]
    ) -> Bool {
        var statement: OpaquePointer?
        let delete = """
        DELETE FROM cluster_model_category_usage
        WHERE origin_node_id = ? AND day = ? AND provider = ?
        """
        guard sqlite3_prepare_v2(db, delete, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, nodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, day, -1, Self.transient)
        sqlite3_bind_text(statement, 3, provider, -1, Self.transient)
        var succeeded = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        statement = nil
        guard succeeded else { return false }

        let insert = """
        INSERT INTO cluster_model_category_usage
          (origin_node_id, day, provider, model, category, tokens)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        for (model, buckets) in categories {
            for (category, tokens) in buckets where tokens > 0 {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, nodeID, -1, Self.transient)
                sqlite3_bind_text(statement, 2, day, -1, Self.transient)
                sqlite3_bind_text(statement, 3, provider, -1, Self.transient)
                sqlite3_bind_text(statement, 4, model, -1, Self.transient)
                sqlite3_bind_text(statement, 5, category, -1, Self.transient)
                sqlite3_bind_int64(statement, 6, Int64(tokens))
                if sqlite3_step(statement) != SQLITE_DONE { return false }
            }
        }
        return true
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

    // MARK: - Link health

    /// 与其余探测表保持一致，让应用里所有时间轴对得上。
    static let meshBucketWidth: TimeInterval = 300

    static func meshBucketStart(_ time: Date) -> Date {
        Date(timeIntervalSince1970:
                (time.timeIntervalSince1970 / meshBucketWidth).rounded(.down) * meshBucketWidth)
    }

    /// 记录一次网格探测。行数由桶宽而非样本数决定，因此和其余聚合表一样不需要清理。
    func recordMeshSample(hostName: String, at time: Date = Date(), rttUs: UInt32?) {
        guard !hostName.isEmpty else { return }
        let bucketAt = Self.meshBucketStart(time).timeIntervalSince1970
        let rtt = rttUs.map { Int($0) }
        queue.sync {
            guard db != nil else { return }
            let sql = """
            INSERT INTO mesh_probe_bucket
              (host_name, bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us)
            VALUES (?, ?, 1, ?, ?, ?, ?)
            ON CONFLICT(host_name, bucket_at) DO UPDATE SET
              samples = samples + 1,
              ok_samples = ok_samples + excluded.ok_samples,
              rtt_min_us = MIN(COALESCE(rtt_min_us, excluded.rtt_min_us),
                               COALESCE(excluded.rtt_min_us, rtt_min_us)),
              rtt_max_us = MAX(COALESCE(rtt_max_us, excluded.rtt_max_us),
                               COALESCE(excluded.rtt_max_us, rtt_max_us)),
              rtt_sum_us = CASE WHEN excluded.rtt_sum_us IS NULL THEN rtt_sum_us
                                ELSE COALESCE(rtt_sum_us, 0) + excluded.rtt_sum_us END
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(statement, 1, hostName, -1, Self.transient)
            sqlite3_bind_double(statement, 2, bucketAt)
            sqlite3_bind_int(statement, 3, rtt == nil ? 0 : 1)
            for index in Int32(4)...Int32(6) {
                if let rtt { sqlite3_bind_int(statement, index, Int32(rtt)) }
                else { sqlite3_bind_null(statement, index) }
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                Log.error("mesh sample write failed", category: "storage")
            }
            sqlite3_finalize(statement)
        }
    }

    /// 某节点的逐桶历史，按时间正序。桶内的 min/max 保留了那五分钟里的抖动幅度，
    /// 这正是“波动情况”要看的东西——只画平均值会把尖峰抹平。
    func meshHistory(hostName: String, since: Date) -> [MeshBucketPoint] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT bucket_at, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us
            FROM mesh_probe_bucket WHERE host_name = ? AND bucket_at >= ?
            ORDER BY bucket_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, hostName, -1, Self.transient)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            var points: [MeshBucketPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let ok = Int(sqlite3_column_int(statement, 2))
                let minimum = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 3))
                let maximum = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 4))
                let sum = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? 0 : Int(sqlite3_column_int(statement, 5))
                points.append(MeshBucketPoint(
                    bucketAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    samples: Int(sqlite3_column_int(statement, 1)),
                    okSamples: ok,
                    rttMinUs: minimum, rttMaxUs: maximum,
                    rttAvgUs: ok > 0 ? sum / ok : nil
                ))
            }
            return points
        }
    }

    /// 把窗口内的桶按节点合并；一次样本都没有的节点不会出现在结果里。
    func meshAggregates(since: Date) -> [String: MeshAggregate] {
        queue.sync {
            guard db != nil else { return [:] }
            let sql = """
            SELECT host_name, samples, ok_samples, rtt_min_us, rtt_max_us, rtt_sum_us
            FROM mesh_probe_bucket WHERE bucket_at >= ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
            var result: [String: MeshAggregate] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(statement, 0))
                var value = result[name] ?? MeshAggregate()
                value.samples += Int(sqlite3_column_int(statement, 1))
                value.okSamples += Int(sqlite3_column_int(statement, 2))
                let minimum = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 3))
                let maximum = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 4))
                if sqlite3_column_type(statement, 5) != SQLITE_NULL {
                    value.rttSumUs += Int(sqlite3_column_int(statement, 5))
                }
                value.rttMinUs = [value.rttMinUs, minimum].compactMap { $0 }.min()
                value.rttMaxUs = [value.rttMaxUs, maximum].compactMap { $0 }.max()
                result[name] = value
            }
            return result
        }
    }

    /// 上一次 STUN 观测到的外部端点，跨进程保留：家庭出口一天可能重拨数次，
    /// 只靠内存状态会让重启前后的那次重拨漏记，因果链就断在那里。
    func lastExternalEndpoint() -> String? {
        queue.sync {
            let result = metadataValueLocked(Self.lastExternalEndpointKey)
            return result.succeeded ? result.value : nil
        }
    }

    @discardableResult
    func setLastExternalEndpoint(_ value: String) -> Bool {
        queue.sync { setMetadataValueLocked(Self.lastExternalEndpointKey, value: value) }
    }

    func recordLinkEvent(_ event: LinkEvent) {
        guard !event.nodeID.isEmpty else { return }
        queue.sync {
            guard db != nil else { return }
            let sql = """
            INSERT OR REPLACE INTO link_event (occurred_at, node_id, kind, detail)
            VALUES (?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                Log.error("link event prepare failed", category: "storage")
                return
            }
            sqlite3_bind_double(statement, 1, event.occurredAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, event.nodeID, -1, Self.transient)
            sqlite3_bind_text(statement, 3, event.kind.rawValue, -1, Self.transient)
            if let detail = event.detail {
                sqlite3_bind_text(statement, 4, detail, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                Log.error("link event write failed", category: "storage")
            }
            sqlite3_finalize(statement)
        }
    }

    func linkEvents(since: Date, limit: Int = 200) -> [LinkEvent] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT occurred_at, node_id, kind, detail FROM link_event
            WHERE occurred_at >= ? ORDER BY occurred_at DESC LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))
            var rows: [LinkEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = LinkEventKind(
                    rawValue: String(cString: sqlite3_column_text(statement, 2))
                ) else { continue }
                rows.append(LinkEvent(
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    nodeID: String(cString: sqlite3_column_text(statement, 1)),
                    kind: kind,
                    detail: sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil : String(cString: sqlite3_column_text(statement, 3))
                ))
            }
            return rows
        }
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
        CREATE TABLE IF NOT EXISTS cluster_hourly_usage (
          origin_node_id TEXT NOT NULL,
          day TEXT NOT NULL,
          hour INTEGER NOT NULL,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          tokens INTEGER NOT NULL,
          PRIMARY KEY (origin_node_id, day, hour, provider, model)
        );
        CREATE TABLE IF NOT EXISTS cluster_model_category_usage (
          origin_node_id TEXT NOT NULL,
          day TEXT NOT NULL,
          provider TEXT NOT NULL,
          model TEXT NOT NULL,
          category TEXT NOT NULL,
          tokens INTEGER NOT NULL,
          PRIMARY KEY (origin_node_id, day, provider, model, category)
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

    /// 只记录出口 NAT 的状态跃迁，行数天然有界，与其余聚合表一样不需要清理逻辑。
    private static func createLinkTables(in db: OpaquePointer?) {
        let sql = """
        CREATE TABLE IF NOT EXISTS mesh_probe_bucket (
          host_name TEXT NOT NULL,
          bucket_at REAL NOT NULL,
          samples INTEGER NOT NULL,
          ok_samples INTEGER NOT NULL,
          rtt_min_us INTEGER,
          rtt_max_us INTEGER,
          rtt_sum_us INTEGER,
          PRIMARY KEY (host_name, bucket_at)
        );
        CREATE TABLE IF NOT EXISTS link_event (
          occurred_at REAL NOT NULL,
          node_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          detail TEXT,
          PRIMARY KEY (occurred_at, node_id, kind)
        );
        CREATE INDEX IF NOT EXISTS idx_link_event_time ON link_event(occurred_at);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.error("link tables create failed", category: "storage")
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
