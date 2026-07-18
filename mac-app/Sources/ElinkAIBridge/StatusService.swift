import Foundation

final class StatusService {
    private struct HookState {
        let state: String
        let at: Date
    }

    private let usage: UsageFetcher
    private let store: UsageStore?
    private weak var cluster: ClusterManager?
    private let lock = NSLock()
    private var cached: BridgeSnapshot?
    private var cachedAt = Date.distantPast
    private var hooks: [String: HookState] = [:]
    private var needsInput: [String: Date] = [:]
    private var historyMaintenanceRetryPending = false

    private static let claudeRoot = URL(
        fileURLWithPath: ("~/.claude/projects" as NSString).expandingTildeInPath)
    private static let codexRoot = URL(
        fileURLWithPath: ("~/.codex/sessions" as NSString).expandingTildeInPath)

    init(usage: UsageFetcher, store: UsageStore? = nil, cluster: ClusterManager? = nil) {
        self.usage = usage
        self.store = store
        self.cluster = cluster
    }

    func snapshot() -> BridgeSnapshot {
        let local = localSnapshotForSync()
        return cluster?.aggregate(local: local) ?? local
    }

    func localSnapshotForSync() -> BridgeSnapshot {
        lock.holding {
            var value: BridgeSnapshot
            if let cached, Date().timeIntervalSince(cachedAt) < 5 {
                value = cached
            } else {
                value = readLogs()
                cached = value
                cachedAt = Date()
            }
            value.generatedAt = Date()
            value.claude = overlay(value.claude, provider: "claude", usage: usage.claude)
            value.codex = overlay(value.codex, provider: "codex", usage: usage.codex)
            value.usageFetchedAt = Self.latestUsageFetchedAt(
                claude: value.claude.usageFetchedAt,
                codex: value.codex.usageFetchedAt
            )
            return value
        }
    }

    static func latestUsageFetchedAt(claude: Date?, codex: Date?) -> Date? {
        [claude, codex].compactMap { $0 }.max()
    }

    func recordEvent(agent: String, event: String, message: String?) {
        guard ["claude", "codex"].contains(agent) else { return }
        lock.holding {
            let now = Date()
            if ["PermissionRequest", "Elicitation"].contains(event)
                || (event == "Notification" && isPermission(message)) {
                needsInput[agent] = now
                return
            }
            let working = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart",
                           "SubagentStop", "PreCompact", "PostCompact", "WorktreeCreate"]
            let idle = ["Stop", "SessionEnd", "SessionStart"]
            if working.contains(event) { hooks[agent] = HookState(state: "working", at: now) }
            else if idle.contains(event) { hooks[agent] = HookState(state: "idle", at: now) }
            else { return }
            needsInput.removeValue(forKey: agent)
        }
    }

    private func overlay(_ input: AgentStatus, provider: String, usage: ProviderUsage) -> AgentStatus {
        var value = input
        value.primary = usage.primary.percent == nil ? value.primary : usage.primary
        value.weekly = usage.weekly.percent == nil ? value.weekly : usage.weekly
        value.error = usage.error
        if usage.primary.percent != nil || usage.weekly.percent != nil {
            value.usageFetchedAt = usage.fetchedAt
            value.usageCached = usage.isCached
        }
        if let hook = hooks[provider] {
            let age = Date().timeIntervalSince(hook.at)
            if hook.state == "working", age < 600 { value.state = "working" }
            if hook.state == "idle", age < 60, value.state == "working" { value.state = "idle" }
        }
        value.needsInput = needsInput[provider].map { Date().timeIntervalSince($0) < 300 } ?? false
        return value
    }

    private func readLogs() -> BridgeSnapshot {
        let timeZone = Self.aggregationCalendar.timeZone
        return BridgeSnapshot(
            claude: readClaude(in: timeZone),
            codex: readCodex(in: timeZone),
            generatedAt: Date(),
            usageFetchedAt: nil
        )
    }

    private func readClaude(in timeZone: TimeZone) -> AgentStatus {
        let files = Self.jsonlFiles(at: Self.claudeRoot) ?? []
        let latest = latestModification(files)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date())
        let dayKey = Self.dayKeyMaker(timeZone)
        let accumulator = ClaudeUsageAccumulator()
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            accumulator.add(lines: text.split(separator: "\n").map(String.init))
        }
        // 只回写今日：今天修改过的文件可能包含更早的行，但早前日期的数据在此并不完整
        let today = dayKey(Date())
        let totals = accumulator.dailyTotals(dayKey: dayKey)[today] ?? [:]
        store?.record(
            day: today, provider: "claude", models: totals,
            expectedBucketTimeZone: timeZone.identifier, preservingResidue: true
        )
        let models = Self.sorted(totals)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models
        )
    }

    private func readCodex(in timeZone: TimeZone) -> AgentStatus {
        let files = Self.jsonlFiles(at: Self.codexRoot) ?? []
        let latest = latestModification(files)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date())
        let dayKey = Self.dayKeyMaker(timeZone)
        var daily: [String: [String: Int]] = [:]
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTimestamp = ""
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map(String.init)
            Self.merge(Self.codexDailyUsage(lines: lines, dayKey: dayKey), into: &daily)
            for line in lines where line.contains("\"token_count\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { continue }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let timestamp = object["timestamp"] as? String ?? ""
                    if timestamp >= latestRateLimitsTimestamp {
                        latestRateLimitsTimestamp = timestamp
                        latestRateLimits = limits
                    }
                }
            }
        }
        let today = dayKey(Date())
        let totals = daily[today] ?? [:]
        store?.record(
            day: today, provider: "codex", models: totals,
            expectedBucketTimeZone: timeZone.identifier, preservingResidue: true
        )
        let models = Self.sorted(totals)
        let windows = latestRateLimits.map(UsageFetcher.codexLogWindows)
        let rateLimitDate = Self.timestamp(latestRateLimitsTimestamp)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models,
            primary: windows?.primary ?? UsageWindow(),
            weekly: windows?.weekly ?? UsageWindow(),
            usageFetchedAt: rateLimitDate,
            usageCached: windows != nil
        )
    }

    /// 一次读取日志，再按一个或多个固定时区分桶。迁移时旧/新时区必须共用
    /// 同一份文件内容，否则两遍读取之间的追加或删除会伪造历史残差。
    private func computeDailyTotals(in timeZones: [TimeZone]) -> [String: UsageHistoryTotals]? {
        guard !timeZones.isEmpty else { return [:] }
        var dayKeys: [String: (Date) -> String] = [:]
        var cutoff = Date.distantFuture
        for timeZone in timeZones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let candidate = calendar.date(
                byAdding: .day, value: -366, to: calendar.startOfDay(for: Date())
            ) ?? .distantPast
            cutoff = min(cutoff, candidate)
            dayKeys[timeZone.identifier] = Self.dayKeyMaker(timeZone)
        }
        let accumulator = ClaudeUsageAccumulator()
        guard let claudeFiles = Self.jsonlFiles(at: Self.claudeRoot),
              let codexFiles = Self.jsonlFiles(at: Self.codexRoot) else {
            Log.warning("usage maintenance could not enumerate history", category: "storage")
            return nil
        }
        for file in claudeFiles {
            guard let modified = modification(file) else {
                Log.warning("usage maintenance could not stat \(file.path)", category: "storage")
                return nil
            }
            guard modified >= cutoff else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                Log.warning("usage maintenance could not read \(file.path)", category: "storage")
                return nil
            }
            accumulator.add(lines: text.split(separator: "\n").map(String.init))
        }
        var codexDaily: [String: DailyUsageTotals] = [:]
        for file in codexFiles {
            guard let modified = modification(file) else {
                Log.warning("usage maintenance could not stat \(file.path)", category: "storage")
                return nil
            }
            guard modified >= cutoff else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                Log.warning("usage maintenance could not read \(file.path)", category: "storage")
                return nil
            }
            // 每个文件只做一次 JSON 解析，再按各时区分桶，迁移时不重复解析
            let events = Self.codexUsageEvents(lines: text.split(separator: "\n").map(String.init))
            for (identifier, dayKey) in dayKeys {
                var totals = codexDaily[identifier] ?? [:]
                Self.merge(Self.bucketCodexEvents(events, dayKey: dayKey), into: &totals)
                codexDaily[identifier] = totals
            }
        }
        var result: [String: UsageHistoryTotals] = [:]
        for (identifier, dayKey) in dayKeys {
            result[identifier] = UsageHistoryTotals(
                claude: accumulator.dailyTotals(dayKey: dayKey),
                codex: codexDaily[identifier] ?? [:]
            )
        }
        return result
    }

    /// 读取不完整时整次失败，不能把暂时读不到的日志误当成“已删除历史”。
    private func computeDailyTotals(in timeZone: TimeZone) -> UsageHistoryTotals? {
        computeDailyTotals(in: [timeZone])?[timeZone.identifier]
    }

    /// 启动时后台回填近一年历史，让统计页首次打开就有周/月/年数据
    @discardableResult
    func backfillHistory(in timeZone: TimeZone? = nil) -> Bool {
        guard let store else { return false }
        let capturedTimeZone = timeZone ?? Self.aggregationCalendar.timeZone
        guard let totals = computeDailyTotals(in: capturedTimeZone) else {
            Log.warning("usage backfill skipped because history scan was incomplete", category: "storage")
            return false
        }
        guard store.mergeBackfillTotals(
            expectedTimeZone: capturedTimeZone.identifier, totals: totals
        ) else {
            Log.warning("usage backfill failed; stored history was left unchanged", category: "storage")
            return false
        }
        Log.info("usage backfill: claude \(totals.claude.count) days, codex \(totals.codex.count) days")
        return true
    }

    /// 旧开发版本曾把标记写到 UserDefaults；SQLite 元数据现在是唯一真源。
    static let appliedBucketTimeZoneKey = "elink_usage_bucket_timezone_v1"

    func usageMaintenanceNeeded() -> Bool {
        guard let store else { return false }
        return Self.shouldRunUsageMaintenance(
            applied: store.usageBucketTimeZone(),
            current: Self.aggregationCalendar.timeZone.identifier,
            retryPending: lock.holding { historyMaintenanceRetryPending }
        )
    }

    static func shouldRunUsageMaintenance(applied: String?, current: String,
                                          retryPending: Bool) -> Bool {
        // Foundation 会把 "UTC" 这类别名规范化成 "GMT"；比较必须在规范化后进行，
        // 否则同一时区的不同写法会造成永不收敛的迁移循环
        retryPending || applied.flatMap(TimeZone.init(identifier:))?.identifier != current
    }

    func retryUsageMaintenanceIfNeeded() {
        guard usageMaintenanceNeeded() else { return }
        runUsageMaintenance()
    }

    /// 启动和时区变化后的统一入口（须在同一条串行队列上执行）：
    /// 日用量、本机快照和时区标记由 UsageStore 在同一个事务中迁移。
    func runUsageMaintenance() {
        guard let store else { return }
        let target = Self.aggregationCalendar.timeZone
        let current = target.identifier
        let applied = store.usageBucketTimeZone()
        // 与 shouldRunUsageMaintenance 相同的规范化比较，别名时区不触发迁移
        if applied.flatMap(TimeZone.init(identifier:))?.identifier == current {
            let succeeded = backfillHistory(in: target)
            lock.holding { historyMaintenanceRetryPending = !succeeded }
            UserDefaults.standard.removeObject(forKey: Self.appliedBucketTimeZoneKey)
            return
        }

        let result: UsageBucketMigrationResult
        if let applied {
            guard let previous = TimeZone(identifier: applied),
                  let totalsByTimeZone = computeDailyTotals(in: [target, previous]),
                  let targetTotals = totalsByTimeZone[current],
                  let oldTotals = totalsByTimeZone[previous.identifier] else {
                Log.warning("usage bucket source timezone is invalid or unreadable: \(applied)",
                            category: "storage")
                return
            }
            result = store.applyBucketMigration(
                expectedSource: applied,
                target: current,
                oldExplained: oldTotals,
                targetTotals: targetTotals
            )
        } else {
            // 老数据库没有来源时区，准确日期不可恢复；UsageStore 会守恒总量，并将
            // 现存日志按目标时区重建、不可解释残差稳定留在原日期。
            guard let targetTotals = computeDailyTotals(in: target) else {
                Log.warning("usage maintenance skipped because history scan was incomplete",
                            category: "storage")
                return
            }
            result = store.applyBucketMigration(
                expectedSource: nil,
                target: current,
                oldExplained: nil,
                targetTotals: targetTotals
            )
        }

        switch result {
        case .applied:
            lock.holding { historyMaintenanceRetryPending = false }
            if store.usageBucketHasLegacyUnknownData(), applied == nil {
                Log.warning("legacy usage buckets normalized with unknown historical timezone",
                            category: "storage")
            } else {
                Log.info("usage history rebucketed \(applied ?? "legacy") -> \(current)")
            }
            UserDefaults.standard.removeObject(forKey: Self.appliedBucketTimeZoneKey)
        case .alreadyCurrent:
            lock.holding { historyMaintenanceRetryPending = false }
            UserDefaults.standard.removeObject(forKey: Self.appliedBucketTimeZoneKey)
        case .sourceChanged:
            lock.holding { historyMaintenanceRetryPending = true }
            Log.info("usage maintenance superseded by a newer timezone change", category: "storage")
        case .failed:
            lock.holding { historyMaintenanceRetryPending = true }
            Log.warning("usage bucket migration failed; previous timezone remains active",
                        category: "storage")
        }
    }

    static func dayKeyMaker(_ timeZone: TimeZone) -> (Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return { formatter.string(from: $0) }
    }

    /// Claude 会话行解析：消息按 id 去重（流式更新/会话续写会跨行、跨文件重复），按天聚合
    final class ClaudeUsageAccumulator {
        // 保存原始时间戳而非 day key，分桶推迟到 dailyTotals，支持按指定时区重分桶
        private var messages: [String: (date: Date, model: String, tokens: Int)] = [:]

        func add(lines: [String]) {
            for line in lines where line.contains("\"usage\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = StatusService.timestamp(object["timestamp"]),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens",
                              "cache_read_input_tokens"].reduce(0) {
                    $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0)
                }
                guard tokens > 0 else { continue }
                let identifier = (message["id"] as? String) ?? (object["uuid"] as? String) ?? line
                if tokens > (messages[identifier]?.tokens ?? -1) {
                    messages[identifier] = (timestamp,
                                            StatusService.normalizedModel(message["model"]), tokens)
                }
            }
        }

        func dailyTotals(dayKey: (Date) -> String = StatusService.dayKey) -> [String: [String: Int]] {
            var totals: [String: [String: Int]] = [:]
            for value in messages.values {
                totals[dayKey(value.date), default: [:]][value.model, default: 0] += value.tokens
            }
            return totals
        }
    }

    /// 单个 Codex 会话文件的行 -> (时间戳, 模型, token 增量) 事件序列。
    /// 增量计算与分桶时区无关，解析一次即可按多个时区分桶。
    static func codexUsageEvents(lines: [String]) -> [(date: Date, model: String, tokens: Int)] {
        var events: [(date: Date, model: String, tokens: Int)] = []
        var model = "unknown"
        var previousTotal: Int?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if let value = payload["model"] as? String, !value.isEmpty {
                model = value
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let cumulative = (total["total_tokens"] as? NSNumber)?.intValue else { continue }

            let last = (info["last_token_usage"] as? [String: Any])
                .flatMap { ($0["total_tokens"] as? NSNumber)?.intValue }
            let delta: Int
            if let previousTotal, cumulative == previousTotal {
                delta = 0
            } else if let last {
                delta = last
            } else if let previousTotal {
                delta = max(0, cumulative - previousTotal)
            } else {
                delta = cumulative
            }
            previousTotal = cumulative

            guard delta > 0, let date = timestamp(object["timestamp"]) else { continue }
            events.append((date, normalizedModel(model), delta))
        }
        return events
    }

    static func bucketCodexEvents(_ events: [(date: Date, model: String, tokens: Int)],
                                  dayKey: (Date) -> String) -> [String: [String: Int]] {
        var totals: [String: [String: Int]] = [:]
        for event in events {
            totals[dayKey(event.date), default: [:]][event.model, default: 0] += event.tokens
        }
        return totals
    }

    /// 单个 Codex 会话文件的行 -> 按天/模型的 token 增量
    static func codexDailyUsage(lines: [String],
                                dayKey: (Date) -> String = StatusService.dayKey) -> [String: [String: Int]] {
        bucketCodexEvents(codexUsageEvents(lines: lines), dayKey: dayKey)
    }

    static func merge(_ addition: [String: [String: Int]], into totals: inout [String: [String: Int]]) {
        for (day, models) in addition {
            for (model, tokens) in models {
                totals[day, default: [:]][model, default: 0] += tokens
            }
        }
    }

    static func dayKey(_ date: Date) -> String {
        dayFormatterLock.holding { dayFormatter.string(from: date) }
    }

    static func startOfAggregationDay(_ date: Date) -> Date {
        aggregationCalendar.startOfDay(for: date)
    }

    /// 集群聚合时区下的 Calendar，日期加减、数据键和显示标签必须共用它
    static var aggregationCalendar: Calendar {
        dayFormatterLock.holding { aggregationCalendarStorage }
    }

    static func setAggregationTimeZone(_ identifier: String?) {
        let timeZone = identifier.flatMap(TimeZone.init(identifier:)) ?? .current
        dayFormatterLock.holding {
            dayFormatter.timeZone = timeZone
            aggregationCalendarStorage.timeZone = timeZone
        }
    }

    private static let dayFormatterLock = NSLock()

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy-MM-dd"
        value.timeZone = .current
        return value
    }()

    private static var aggregationCalendarStorage: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }()

    private static func sorted(_ totals: [String: Int]) -> [ModelUsage] {
        totals.map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
    }

    private static func normalizedModel(_ value: Any?) -> String {
        guard let model = value as? String else { return "unknown" }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return fractionalTimestamp.date(from: value) ?? basicTimestamp.date(from: value)
    }

    private static let fractionalTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicTimestamp = ISO8601DateFormatter()

    static func jsonlFiles(at root: URL) -> [URL]? {
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) {
                return []
            }
            Log.warning("usage history root is inaccessible: \(error.localizedDescription)",
                        category: "storage")
            return nil
        }
        guard values.isDirectory == true else { return nil }
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else { return nil }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
        if let traversalError {
            Log.warning("usage history enumeration failed: \(traversalError.localizedDescription)",
                        category: "storage")
            return nil
        }
        return files
    }

    private func latestModification(_ files: [URL]) -> Date? { files.compactMap(modification).max() }
    private func modification(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    private func state(_ date: Date?) -> String {
        guard let age = date.map({ Date().timeIntervalSince($0) }) else { return "offline" }
        if age < 20 { return "working" }
        if age < 1800 { return "idle" }
        return "offline"
    }
    private func isPermission(_ message: String?) -> Bool {
        guard let text = message?.lowercased() else { return false }
        return text.contains("permission") || text.contains("approve") || text.contains("approval")
    }
}
