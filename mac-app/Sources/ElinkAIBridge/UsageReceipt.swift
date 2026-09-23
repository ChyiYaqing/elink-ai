import Foundation

/// 对账单上的一张小票：选定范围内 Claude 与 Codex 的 API 等价成本和 token 明细。
///
/// 与统计页同一个口径——费用来自 模型×分类 明细、同一张定价表，所以它**不是**
/// 真实扣费，小票上必须写明「API 等价估算」。
struct UsageReceipt: Equatable {
    struct Line: Equatable {
        let model: String
        let tokens: Int
        /// nil = 该模型没有公开定价，费用未计入
        let cost: Double?
    }

    struct Client: Equatable {
        let provider: String
        let name: String
        let cost: Double
        let lines: [Line]
    }

    let range: StatsRange
    let start: Date
    let issuedAt: Date
    let clients: [Client]
    let totalCost: Double
    let totalTokens: Int
    /// 输入含缓存读写；输出含推理
    let input: Int
    let output: Int
    let cacheRead: Int
    /// 分类明细覆盖了总 token 的多大比例；不足时金额偏低，要说出来
    let coverage: Double
    let unpriced: [String]
    /// 本机 transcript 统计出的会话数；nil = 尚未统计
    let sessions: Int?

    var cacheHitRate: Double? { input > 0 ? Double(cacheRead) / Double(input) : nil }
    var isEmpty: Bool { totalTokens == 0 && clients.isEmpty }

    static let providers: [(key: String, name: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex CLI"),
    ]

    /// 范围窗口的起点，与 `UsageStats.windowFilter` 的天键一致：
    /// 日 = 今天，周/月 = 最近 7/30 天，年 = 最近 12 个自然月。
    static func windowStart(range: StatsRange, now: Date = Date()) -> Date {
        let calendar = StatusService.aggregationCalendar
        let today = calendar.startOfDay(for: now)
        switch range {
        case .day: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .year:
            let month = calendar.date(byAdding: .month, value: -11, to: today) ?? today
            return calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        }
    }

    static func make(range: StatsRange, now: Date = Date(),
                     usage: [String: [DailyModelUsage]],
                     modelCategories: [String: [ModelCategoryUsage]],
                     sessions: Int?,
                     table: [String: ModelPricing] = Pricing.table()) -> UsageReceipt {
        let inWindow = UsageStats.windowFilter(range: range, now: now)
        var clients: [Client] = []
        var totalTokens = 0, input = 0, output = 0, cacheRead = 0, categorized = 0
        var unpriced = Set<String>()
        for (key, name) in providers {
            var tokensByModel: [String: Int] = [:]
            for row in usage[key] ?? [] where inWindow(row.day) {
                tokensByModel[row.model, default: 0] += row.tokens
            }
            var categoriesByModel: [String: [String: Int]] = [:]
            for row in modelCategories[key] ?? [] where inWindow(row.day) {
                categoriesByModel[row.model, default: [:]][row.category, default: 0] += row.tokens
                categorized += row.tokens
                switch row.category {
                case "cache_read": cacheRead += row.tokens; input += row.tokens
                case "input", "cache_write": input += row.tokens
                case "output", "reasoning": output += row.tokens
                default: break
                }
            }
            let models = Set(tokensByModel.keys).union(categoriesByModel.keys)
            var lines = models.map { model -> Line in
                let categories = categoriesByModel[model] ?? [:]
                let cost = Pricing.cost(model: model, categories: categories, table: table)
                if cost == nil { unpriced.insert(model) }
                return Line(model: model,
                             tokens: tokensByModel[model] ?? categories.values.reduce(0, +),
                             cost: cost)
            }
            lines = lines.filter { $0.tokens > 0 }
            guard !lines.isEmpty else { continue }
            // 贵的在前；同价（多为无定价）按用量
            lines.sort { ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens) }
            totalTokens += lines.reduce(0) { $0 + $1.tokens }
            clients.append(Client(provider: key, name: name,
                                  cost: lines.reduce(0) { $0 + ($1.cost ?? 0) }, lines: lines))
        }
        return UsageReceipt(
            range: range, start: windowStart(range: range, now: now), issuedAt: now,
            clients: clients, totalCost: clients.reduce(0) { $0 + $1.cost },
            totalTokens: totalTokens, input: input, output: output, cacheRead: cacheRead,
            coverage: UsageStats.costCoverage(pricedTokens: categorized, windowTokens: totalTokens),
            unpriced: unpriced.sorted(), sessions: sessions)
    }

    /// `since` 之后有写入的本机会话数。
    ///
    /// 文件 mtime 是最后一次写入的时间，而窗口的终点总是「现在」，所以
    /// 「mtime ≥ 窗口起点」恰好等价于「窗口内写过这个会话」。
    /// Claude 只算项目目录下的顶层 transcript（子代理在更深的 subagents/ 里，
    /// worktree 代理目录也跳过）；Codex 跳过带 parent_thread_id 的子代理 rollout。
    static func sessionCount(since: Date, claudeRoot: URL, codexRoot: URL) -> Int {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        var count = 0
        let projects = (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil)) ?? []
        for project in projects where !project.lastPathComponent.contains("-claude-worktrees-agent-") {
            let files = (try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            count += files.filter { $0.pathExtension == "jsonl" && (modified($0) ?? .distantPast) >= since }.count
        }
        if let rollouts = fm.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let file as URL in rollouts
            where file.pathExtension == "jsonl" && (modified(file) ?? .distantPast) >= since {
                if !isCodexSubagent(file) { count += 1 }
            }
        }
        return count
    }

    /// 子代理的 session_meta 首行带非空 parent_thread_id。首行可能有几十 KB
    /// （内嵌了指令），只读够首行的长度。
    private static func isCodexSubagent(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 131_072) else { return false }
        let firstLine = head.split(separator: 0x0A, maxSplits: 1).first ?? head[...]
        return String(decoding: firstLine, as: UTF8.self).contains(#""parent_thread_id":""#)
    }
}
