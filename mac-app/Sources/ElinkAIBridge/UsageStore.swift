import Foundation
import SQLite3

struct DailyModelUsage: Equatable {
    var day: String      // 本地时区 "yyyy-MM-dd"
    var provider: String // "claude" / "codex"
    var model: String
    var tokens: Int
    var nodeID: String? = nil
}

/// 每日各模型 token 用量的 SQLite 持久化，避免会话日志被清理后丢失历史
final class UsageStore {
    static let shared = UsageStore()

    private let queue = DispatchQueue(label: "elink.usage-store")
    private let databasePath: String
    private var db: OpaquePointer?
    private var clusterNodeID: String?
    private var clusterAggregationEnabled = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let noResetMaxAge: TimeInterval = 6 * 60 * 60
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

    /// 覆盖写入某天某 provider 的各模型用量（值为当日重算的总量而非增量）
    func record(day: String, provider: String, models: [String: Int]) {
        let rows = models.filter { $0.value > 0 }
        if !rows.isEmpty {
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
        if let descriptor = recordLocalClusterSnapshot(day: day, provider: provider, models: models) {
            onClusterUsageChange?([descriptor])
        }
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
            upsertNodeLocked(ClusterNodeRecord(
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
        if saved { Self.protectDatabaseFiles(at: databasePath) }
        return saved
    }

    /// Removes data learned from a previous cluster while preserving this Mac's own history.
    func resetRemoteClusterData(localNodeID: String) {
        queue.sync {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
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
            sqlite3_exec(db, succeeded ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        }
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

    @discardableResult
    func mergeClusterSnapshots(_ snapshots: [ClusterUsageSnapshot]) -> [ClusterSnapshotDescriptor] {
        let accepted = queue.sync {
            snapshots.compactMap { snapshot -> ClusterSnapshotDescriptor? in
                guard ["claude", "codex"].contains(snapshot.key.provider),
                      snapshot.key.day.count == 10,
                      snapshot.models.count <= 100,
                      snapshot.models.allSatisfy({ !$0.key.isEmpty && $0.value >= 0 }) else { return nil }
                return writeSnapshotLocked(snapshot, requireNewer: true) ? snapshot.descriptor : nil
            }
        }
        if !accepted.isEmpty { onClusterUsageChange?(accepted) }
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

    func upsertClusterNode(_ node: ClusterNodeRecord) {
        queue.sync { upsertNodeLocked(node) }
    }

    private func recordLocalClusterSnapshot(day: String, provider: String,
                                            models: [String: Int]) -> ClusterSnapshotDescriptor? {
        queue.sync {
            guard let nodeID = clusterNodeID else { return nil }
            let key = ClusterSnapshotKey(originNodeID: nodeID, day: day, provider: provider)
            let clean = models.filter { $0.value > 0 }
            let existing = snapshotLocked(key)
            guard existing?.models != clean else { return nil }
            let snapshot = ClusterUsageSnapshot(
                key: key,
                revision: (existing?.revision ?? 0) + 1,
                observedAt: Date(),
                models: clean
            )
            return writeSnapshotLocked(snapshot, requireNewer: true) ? snapshot.descriptor : nil
        }
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

    private func writeSnapshotLocked(_ snapshot: ClusterUsageSnapshot, requireNewer: Bool) -> Bool {
        if requireNewer, let existing = snapshotLocked(snapshot.key), existing.revision >= snapshot.revision {
            if existing.revision == snapshot.revision, existing.models != snapshot.models {
                Log.warning("cluster snapshot conflict origin=\(snapshot.key.originNodeID) revision=\(snapshot.revision)",
                            category: "cluster")
            }
            return false
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
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
        sqlite3_finalize(statement)

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
        sqlite3_exec(db, succeeded ? "COMMIT" : "ROLLBACK", nil, nil, nil)
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

    private func upsertNodeLocked(_ node: ClusterNodeRecord) {
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
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, node.nodeID, -1, Self.transient)
        sqlite3_bind_text(statement, 2, node.name, -1, Self.transient)
        if let endpoint = node.endpoint { sqlite3_bind_text(statement, 3, endpoint, -1, Self.transient) }
        else { sqlite3_bind_null(statement, 3) }
        if let seen = node.lastSeenAt { sqlite3_bind_double(statement, 4, seen.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 4) }
        if let sync = node.lastSyncAt { sqlite3_bind_double(statement, 5, sync.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, 5) }
        sqlite3_step(statement)
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
