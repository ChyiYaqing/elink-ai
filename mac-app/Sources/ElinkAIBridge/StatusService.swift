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
        BridgeSnapshot(
            claude: readClaude(),
            codex: readCodex(),
            generatedAt: Date(),
            usageFetchedAt: nil
        )
    }

    private func readClaude() -> AgentStatus {
        let files = jsonlFiles(Self.claudeRoot)
        let latest = latestModification(files)
        let start = Self.startOfAggregationDay(Date())
        let accumulator = ClaudeUsageAccumulator()
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            accumulator.add(lines: text.split(separator: "\n").map(String.init))
        }
        // 只回写今日：今天修改过的文件可能包含更早的行，但早前日期的数据在此并不完整
        let today = Self.dayKey(Date())
        let totals = accumulator.dailyTotals()[today] ?? [:]
        store?.record(day: today, provider: "claude", models: totals)
        let models = Self.sorted(totals)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models
        )
    }

    private func readCodex() -> AgentStatus {
        let files = jsonlFiles(Self.codexRoot)
        let latest = latestModification(files)
        let start = Self.startOfAggregationDay(Date())
        var daily: [String: [String: Int]] = [:]
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTimestamp = ""
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map(String.init)
            Self.merge(Self.codexDailyUsage(lines: lines), into: &daily)
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
        let today = Self.dayKey(Date())
        let totals = daily[today] ?? [:]
        store?.record(day: today, provider: "codex", models: totals)
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

    /// 启动时后台回填近一年历史，让统计页首次打开就有周/月/年数据
    func backfillHistory() {
        guard let store else { return }
        let cutoff = Self.aggregationCalendar.date(
            byAdding: .day, value: -366, to: Self.startOfAggregationDay(Date())) ?? .distantPast
        let accumulator = ClaudeUsageAccumulator()
        for file in jsonlFiles(Self.claudeRoot) where (modification(file) ?? .distantPast) >= cutoff {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            accumulator.add(lines: text.split(separator: "\n").map(String.init))
        }
        let claudeDaily = accumulator.dailyTotals()
        for (day, models) in claudeDaily {
            store.record(day: day, provider: "claude", models: models)
        }
        var codexDaily: [String: [String: Int]] = [:]
        for file in jsonlFiles(Self.codexRoot) where (modification(file) ?? .distantPast) >= cutoff {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            Self.merge(Self.codexDailyUsage(lines: text.split(separator: "\n").map(String.init)),
                       into: &codexDaily)
        }
        for (day, models) in codexDaily {
            store.record(day: day, provider: "codex", models: models)
        }
        Log.info("usage backfill: claude \(claudeDaily.count) days, codex \(codexDaily.count) days")
    }

    /// Claude 会话行解析：消息按 id 去重（流式更新/会话续写会跨行、跨文件重复），按天聚合
    final class ClaudeUsageAccumulator {
        private var messages: [String: (day: String, model: String, tokens: Int)] = [:]

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
                    messages[identifier] = (StatusService.dayKey(timestamp),
                                            StatusService.normalizedModel(message["model"]), tokens)
                }
            }
        }

        func dailyTotals() -> [String: [String: Int]] {
            var totals: [String: [String: Int]] = [:]
            for value in messages.values {
                totals[value.day, default: [:]][value.model, default: 0] += value.tokens
            }
            return totals
        }
    }

    /// 单个 Codex 会话文件的行 -> 按天/模型的 token 增量
    static func codexDailyUsage(lines: [String]) -> [String: [String: Int]] {
        var totals: [String: [String: Int]] = [:]
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
            totals[dayKey(date), default: [:]][normalizedModel(model), default: 0] += delta
        }
        return totals
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

    private func jsonlFiles(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
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
