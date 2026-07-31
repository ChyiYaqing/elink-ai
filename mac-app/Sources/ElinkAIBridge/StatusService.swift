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
    /// Claude transcript 的增量读取状态：每个文件已经解析到第几个字节，以及跨轮
    /// 保留的累加器。
    ///
    /// 以前每轮都把当天的 transcript 从第 0 字节整个重读一遍。这份工作量正比于
    /// 「今天写了多少」，而它每 5 秒发生一次：实测 13.5MB 要 680ms，一天下来越攒
    /// 越慢——一个只是在后台报数的菜单栏应用，稳定占掉一个核的 15%，傍晚更高。
    ///
    /// 累加器按 message id 去重、同一 id 取较大值，所以只喂新追加的字节，结果与
    /// 全量重放一致。
    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeAccumulator = ClaudeUsageAccumulator()
    private var claudeAccumulatorKey = ""
    /// Codex 的解析器跨行有状态（从累计值算增量），不适合切成片段喂。这里只做
    /// 「文件没动过就不重解析」，随时间变化的 state 仍然每轮重算。
    private var codexCache: (latest: Date?, status: AgentStatus)?

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
        // 只回写今日：今天修改过的文件可能包含更早的行，但早前日期的数据在此并不完整
        let today = dayKey(Date())
        // 跨天或改时区就重来：累加器只该装当天、且按当前时区分桶的数据
        let key = "\(today)\u{1f}\(timeZone.identifier)"
        if claudeAccumulatorKey != key {
            claudeAccumulator = ClaudeUsageAccumulator()
            claudeOffsets = [:]
            claudeAccumulatorKey = key
        }
        let accumulator = claudeAccumulator
        for file in files where (modification(file) ?? .distantPast) >= start {
            appendNewClaudeLines(of: file, into: accumulator)
        }
        let totals = accumulator.dailyTotals(dayKey: dayKey)[today] ?? [:]
        store?.record(
            day: today, provider: "claude", models: totals,
            expectedBucketTimeZone: timeZone.identifier, preservingResidue: true
        )
        store?.recordHourly(
            day: today, provider: "claude",
            hours: Self.hourBuckets(
                from: accumulator.dailyTotals(dayKey: Self.hourKeyMaker(timeZone)), day: today),
            expectedBucketTimeZone: timeZone.identifier
        )
        store?.recordCategories(
            day: today, provider: "claude",
            categories: accumulator.dailyCategoryTotals(dayKey: dayKey)[today] ?? [:],
            expectedBucketTimeZone: timeZone.identifier
        )
        let models = Self.sorted(totals)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models
        )
    }

    /// 只把上次之后追加的字节喂给累加器。
    ///
    /// 停在最后一个换行符：JSONL 是一边写一边读的，最后一行很可能只写了一半，
    /// 解析半行只会得到一条解不开的记录，而下一轮它就完整了。
    /// 这一轮该从哪个字节读起；nil 表示没有新内容，连打开文件都不必。
    ///
    /// 比记下的偏移量还短，说明文件被截断或整个换掉了（会话重写、日志轮换），
    /// 这时旧偏移量指向的位置已经不是原来那行，只能从头再来。累加器按 message id
    /// 去重，重放一遍不会把用量算两次。
    static func resumeOffset(size: UInt64, recorded: UInt64) -> UInt64? {
        let from = size < recorded ? 0 : recorded
        return size > from ? from : nil
    }

    private func appendNewClaudeLines(of file: URL, into accumulator: ClaudeUsageAccumulator) {
        let path = file.path
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        let total = UInt64(size)
        guard let from = Self.resumeOffset(size: total, recorded: claudeOffsets[path] ?? 0) else {
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: from)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty,
              let lastBreak = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastBreak]
        accumulator.add(lines: complete.split(separator: 0x0A).compactMap {
            String(data: Data($0), encoding: .utf8)
        })
        claudeOffsets[path] = from + UInt64(data.distance(from: data.startIndex, to: lastBreak)) + 1
    }

    private func readCodex(in timeZone: TimeZone) -> AgentStatus {
        let files = Self.jsonlFiles(at: Self.codexRoot) ?? []
        let latest = latestModification(files)
        // 文件一个字节都没动过，重解析一遍必然得到同样的数字。唯独 state 要重算：
        // 它是拿最后写入时间和此刻比出来的，同一份文件放着不动也会从「工作中」
        // 变成「空闲」。
        if let cache = codexCache, cache.latest == latest {
            var status = cache.status
            status.state = state(latest)
            return status
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date())
        let dayKey = Self.dayKeyMaker(timeZone)
        let hourKey = Self.hourKeyMaker(timeZone)
        var daily: [String: [String: Int]] = [:]
        var hourlyKeyed: [String: [String: Int]] = [:]
        var dailyCategories: [String: [String: Int]] = [:]
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTimestamp = ""
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map(String.init)
            // 事件解析一次，按天/按小时/按分类各分桶一遍
            let events = Self.codexUsageEvents(lines: lines)
            Self.merge(Self.bucketCodexEvents(events, dayKey: dayKey), into: &daily)
            Self.merge(Self.bucketCodexEvents(events, dayKey: hourKey), into: &hourlyKeyed)
            Self.merge(Self.bucketCodexCategories(events, dayKey: dayKey), into: &dailyCategories)
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
        store?.recordHourly(
            day: today, provider: "codex",
            hours: Self.hourBuckets(from: hourlyKeyed, day: today),
            expectedBucketTimeZone: timeZone.identifier
        )
        store?.recordCategories(
            day: today, provider: "codex",
            categories: dailyCategories[today] ?? [:],
            expectedBucketTimeZone: timeZone.identifier
        )
        let models = Self.sorted(totals)
        let windows = latestRateLimits.map(UsageFetcher.codexLogWindows)
        let rateLimitDate = Self.timestamp(latestRateLimitsTimestamp)
        let status = AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models,
            primary: windows?.primary ?? UsageWindow(),
            weekly: windows?.weekly ?? UsageWindow(),
            usageFetchedAt: rateLimitDate,
            usageCached: windows != nil
        )
        codexCache = (latest, status)
        return status
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

    /// 解析行为变化时递增：触发一次精确重建，清洗旧解析器写入的错误归因。
    /// v2：subagent 文件里模型声明前的 token_count 归属文件首个声明的模型。
    static let usageParserVersion = "2"

    /// 启动时后台回填近一年历史，让统计页首次打开就有周/月/年数据
    @discardableResult
    func backfillHistory(in timeZone: TimeZone? = nil, exact: Bool = false) -> Bool {
        guard let store else { return false }
        let capturedTimeZone = timeZone ?? Self.aggregationCalendar.timeZone
        guard let totals = computeDailyTotals(in: capturedTimeZone) else {
            Log.warning("usage backfill skipped because history scan was incomplete", category: "storage")
            return false
        }
        guard store.mergeBackfillTotals(
            expectedTimeZone: capturedTimeZone.identifier, totals: totals,
            exact: exact,
            recordingParserVersion: exact ? Self.usageParserVersion : nil
        ) else {
            Log.warning("usage backfill failed; stored history was left unchanged", category: "storage")
            return false
        }
        if exact {
            Log.info("usage history rebuilt for parser v\(Self.usageParserVersion)")
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
            retryPending: lock.holding { historyMaintenanceRetryPending },
            parserOutdated: store.usageParserVersion() != Self.usageParserVersion
        )
    }

    static func shouldRunUsageMaintenance(applied: String?, current: String,
                                          retryPending: Bool,
                                          parserOutdated: Bool = false) -> Bool {
        // Foundation 会把 "UTC" 这类别名规范化成 "GMT"；比较必须在规范化后进行，
        // 否则同一时区的不同写法会造成永不收敛的迁移循环
        retryPending || parserOutdated
            || applied.flatMap(TimeZone.init(identifier:))?.identifier != current
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
            // 解析器升级后先做一次精确重建，清洗旧解析器的错误归因；
            // 时区迁移与版本升级同时发生时，迁移先行，下一轮维护再精确重建
            let exact = store.usageParserVersion() != Self.usageParserVersion
            let succeeded = backfillHistory(in: target, exact: exact)
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

    /// "yyyy-MM-dd HH"，与 dayKeyMaker 相同的固定时区捕获语义，供小时分桶
    static func hourKeyMaker(_ timeZone: TimeZone) -> (Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH"
        formatter.timeZone = timeZone
        return { formatter.string(from: $0) }
    }

    /// 从 hourKey 分桶结果中取出指定 day 的各小时桶（0..23）
    static func hourBuckets(from keyed: [String: [String: Int]],
                            day: String) -> [Int: [String: Int]] {
        var buckets: [Int: [String: Int]] = [:]
        let prefix = day + " "
        for (key, models) in keyed where key.hasPrefix(prefix) {
            guard let hour = Int(key.dropFirst(prefix.count)), (0..<24).contains(hour) else { continue }
            buckets[hour] = models
        }
        return buckets
    }

    /// Claude usage 字段 -> 统一分类键；四类互不重叠，加和即消息总量
    private static let claudeCategoryFields = [
        ("input_tokens", "input"),
        ("output_tokens", "output"),
        ("cache_creation_input_tokens", "cache_write"),
        ("cache_read_input_tokens", "cache_read"),
    ]

    /// Claude 会话行解析：消息按 id 去重（流式更新/会话续写会跨行、跨文件重复），按天聚合
    final class ClaudeUsageAccumulator {
        // 保存原始时间戳而非 day key，分桶推迟到 dailyTotals，支持按指定时区重分桶
        private var messages:
            [String: (date: Date, model: String, tokens: Int, categories: [String: Int])] = [:]

        func add(lines: [String]) {
            for line in lines where line.contains("\"usage\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = StatusService.timestamp(object["timestamp"]),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                var categories: [String: Int] = [:]
                var tokens = 0
                for (field, category) in StatusService.claudeCategoryFields {
                    let value = (usage[field] as? NSNumber)?.intValue ?? 0
                    tokens += value
                    if value > 0 { categories[category] = value }
                }
                guard tokens > 0 else { continue }
                let identifier = (message["id"] as? String) ?? (object["uuid"] as? String) ?? line
                if tokens > (messages[identifier]?.tokens ?? -1) {
                    messages[identifier] = (timestamp,
                                            StatusService.normalizedModel(message["model"]),
                                            tokens, categories)
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

        /// 按天聚合的 token 分类用量，键为 input/output/cache_write/cache_read
        func dailyCategoryTotals(
            dayKey: (Date) -> String = StatusService.dayKey
        ) -> [String: [String: Int]] {
            var totals: [String: [String: Int]] = [:]
            for value in messages.values {
                for (category, tokens) in value.categories {
                    totals[dayKey(value.date), default: [:]][category, default: 0] += tokens
                }
            }
            return totals
        }
    }

    /// 单个 Codex 会话文件的行 -> (时间戳, 模型, token 增量, 分类增量) 事件序列。
    /// 增量计算与分桶时区无关，解析一次即可按多个时区分桶。
    /// subagent 会话会先写 token_count、之后才声明模型；模型声明前的事件
    /// 归属文件首个声明的模型，文件从头到尾没有模型时才落到 "unknown"。
    static func codexUsageEvents(
        lines: [String]
    ) -> [(date: Date, model: String, tokens: Int, categories: [String: Int])] {
        var events: [(date: Date, model: String?, tokens: Int, categories: [String: Int])] = []
        var model: String?
        var firstModel: String?
        var previousTotal: Int?
        var previousFields: [String: Int] = [:]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if let value = payload["model"] as? String, !value.isEmpty {
                model = value
                if firstModel == nil { firstModel = value }
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let cumulative = (total["total_tokens"] as? NSNumber)?.intValue else { continue }

            let lastUsage = info["last_token_usage"] as? [String: Any]
            let last = lastUsage.flatMap { ($0["total_tokens"] as? NSNumber)?.intValue }
            let cumulativeFields = codexCategoryFieldValues(total)
            let delta: Int
            let deltaFields: [String: Int]
            if let previousTotal, cumulative == previousTotal {
                delta = 0
                deltaFields = [:]
            } else if let last {
                delta = last
                deltaFields = lastUsage.map(codexCategoryFieldValues) ?? [:]
            } else if let previousTotal {
                delta = max(0, cumulative - previousTotal)
                deltaFields = cumulativeFields.reduce(into: [:]) { result, entry in
                    result[entry.key] = max(0, entry.value - (previousFields[entry.key] ?? 0))
                }
            } else {
                delta = cumulative
                deltaFields = cumulativeFields
            }
            previousTotal = cumulative
            previousFields = cumulativeFields

            guard delta > 0, let date = timestamp(object["timestamp"]) else { continue }
            events.append((date, model, delta, codexDisjointCategories(deltaFields)))
        }
        return events.map { (date: $0.date, model: normalizedModel($0.model ?? firstModel),
                             tokens: $0.tokens, categories: $0.categories) }
    }

    /// Codex token_count 用量字典中与分类相关的原始字段值
    private static func codexCategoryFieldValues(_ usage: [String: Any]) -> [String: Int] {
        var values: [String: Int] = [:]
        for field in ["input_tokens", "cached_input_tokens",
                      "output_tokens", "reasoning_output_tokens"] {
            values[field] = (usage[field] as? NSNumber)?.intValue ?? 0
        }
        return values
    }

    /// Codex 的 cached ⊆ input、reasoning ⊆ output，扣除重叠后各分类互不相交
    static func codexDisjointCategories(_ fields: [String: Int]) -> [String: Int] {
        let cached = max(0, fields["cached_input_tokens"] ?? 0)
        let reasoning = max(0, fields["reasoning_output_tokens"] ?? 0)
        var categories: [String: Int] = [:]
        let input = max(0, (fields["input_tokens"] ?? 0) - cached)
        let output = max(0, (fields["output_tokens"] ?? 0) - reasoning)
        if input > 0 { categories["input"] = input }
        if output > 0 { categories["output"] = output }
        if cached > 0 { categories["cache_read"] = cached }
        if reasoning > 0 { categories["reasoning"] = reasoning }
        return categories
    }

    static func bucketCodexEvents(
        _ events: [(date: Date, model: String, tokens: Int, categories: [String: Int])],
        dayKey: (Date) -> String
    ) -> [String: [String: Int]] {
        var totals: [String: [String: Int]] = [:]
        for event in events {
            totals[dayKey(event.date), default: [:]][event.model, default: 0] += event.tokens
        }
        return totals
    }

    static func bucketCodexCategories(
        _ events: [(date: Date, model: String, tokens: Int, categories: [String: Int])],
        dayKey: (Date) -> String
    ) -> [String: [String: Int]] {
        var totals: [String: [String: Int]] = [:]
        for event in events {
            for (category, tokens) in event.categories {
                totals[dayKey(event.date), default: [:]][category, default: 0] += tokens
            }
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
