import Foundation

/// 一个模型每百万 token 的美元单价，四个分类各一份。
struct ModelPricing: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    /// 分类键 -> 单价。reasoning 是 Codex 的推理 token，OpenAI 按输出价计费。
    func rate(for category: String) -> Double? {
        switch category {
        case "input": return input
        case "output", "reasoning": return output
        case "cache_read": return cacheRead
        case "cache_write": return cacheWrite
        default: return nil
        }
    }
}

/// 把 token 用量折算成「同样的量走官方 API 要花多少钱」。
///
/// 算的**不是**真实账单：日常用量走的是 Claude / ChatGPT 订阅，额度内不按 token 收费。
/// 这个数只回答「这些用量的 API 等价成本是多少」，UI 必须照这个口径措辞，
/// 不能显示成已扣款金额。
///
/// 未知模型一律返回 nil 而不是当成 0：静默算成 0 会让总额看着正常却少算一截，
/// 比缺一个数更难发现。调用方负责把「无定价」显式说出来。
enum Pricing {
    /// 官方公布价，2026-09-23 核对。
    ///
    /// Anthropic 不单独公布缓存价，按其规则推导：缓存写取 5 分钟 TTL 的 1.25×input
    /// （1 小时 TTL 是 2×，日志里区分不出来，取常用的那档）；缓存读一般是 0.1×input，
    /// 但 Opus 5.5 是 0.05×。claude-sonnet-5 的 2/10 原是首发优惠价，官方已改为正式价。
    ///
    /// OpenAI 是逐档公布的原值，这里取短上下文档。单次输入超过 272K token 的请求
    /// 官方按 2× 输入/缓存、1.5× 输出计费，而日志只有按天的分类汇总、看不出单次
    /// 请求多长，长上下文用得多时会少算。gpt-5.6-sol 是促销价，官方称至少持续到
    /// 2026-11-21，到期后要按官网回调。codex-auto-review 没有官方公布价，不收录。
    static let builtIn: [String: ModelPricing] = [
        "claude-fable-5": ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-opus-5-5": ModelPricing(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        "claude-opus-5": ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-5": ModelPricing(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-6-astra": ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "gpt-6-sol": ModelPricing(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "gpt-5.6-sol": ModelPricing(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        "gpt-5.6-luna": ModelPricing(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
        "gemini-2.5-pro": ModelPricing(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "gemini-2.5-flash": ModelPricing(input: 0.30, output: 2.50, cacheRead: 0.03, cacheWrite: 0),
        "gemini-2.5-flash-lite": ModelPricing(input: 0.10, output: 0.40, cacheRead: 0.01, cacheWrite: 0),
        "gemini-3-pro-preview": ModelPricing(input: 2.0, output: 12.0, cacheRead: 0.2, cacheWrite: 0),
        "gemini-3-flash-preview": ModelPricing(input: 0.5, output: 3.0, cacheRead: 0.05, cacheWrite: 0),
        "gemini-3.5-flash": ModelPricing(input: 1.50, output: 9.0, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.5-flash-lite": ModelPricing(input: 0.10, output: 0.40, cacheRead: 0.01, cacheWrite: 0),
        "gemini-3.8-flash": ModelPricing(input: 0.75, output: 3.75, cacheRead: 0.0375, cacheWrite: 0),
        "gemini-4-neon": ModelPricing(input: 3.0, output: 15.0, cacheRead: 0.15, cacheWrite: 0),
        "gemini-4-argon": ModelPricing(input: 2.0, output: 10.0, cacheRead: 0.10, cacheWrite: 0),
    ]

    /// 用户覆盖表所在位置，与 usage.db 同目录。
    static var overridePath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElinkAI", isDirectory: true)
            .appendingPathComponent("pricing.json").path
    }

    /// 内置表叠加用户覆盖。价格会变、新模型会出现，靠发版跟不上。
    static func table(overridePath: String = Pricing.overridePath) -> [String: ModelPricing] {
        builtIn.merging(loadOverrides(path: overridePath)) { _, override in override }
    }

    /// 覆盖文件格式：{"model-name": {"input": 5, "output": 25,
    ///                              "cache_read": 0.5, "cache_write": 6.25}}
    /// 缺字段按 0 计，整个文件坏掉就当没有——宁可用内置价，也不要让面板打不开。
    static func loadOverrides(path: String) -> [String: ModelPricing] {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var table: [String: ModelPricing] = [:]
        for (model, value) in object {
            guard let fields = value as? [String: Any] else { continue }
            func rate(_ key: String) -> Double {
                ((fields[key] as? NSNumber)?.doubleValue).map { max(0, $0) } ?? 0
            }
            table[model] = ModelPricing(input: rate("input"), output: rate("output"),
                                        cacheRead: rate("cache_read"),
                                        cacheWrite: rate("cache_write"))
        }
        return table
    }

    /// 一个模型某几类 token 的等价成本，单位美元。无定价返回 nil。
    static func cost(model: String, categories: [String: Int],
                     table: [String: ModelPricing]) -> Double? {
        guard let pricing = table[model] else { return nil }
        var total = 0.0
        for (category, tokens) in categories where tokens > 0 {
            guard let rate = pricing.rate(for: category) else { continue }
            total += Double(tokens) / 1_000_000 * rate
        }
        return total
    }

    /// 一批用量的合计成本，以及其中没有定价、因此没被计入的模型。
    /// 调用方必须把 `unpriced` 显示出来，否则总额会被当成全部。
    static func total(rows: [ModelCategoryUsage],
                      table: [String: ModelPricing] = Pricing.table())
        -> (cost: Double, unpriced: Set<String>) {
        var cost = 0.0
        var unpriced: Set<String> = []
        for row in rows {
            guard let pricing = table[row.model] else {
                unpriced.insert(row.model)
                continue
            }
            guard let rate = pricing.rate(for: row.category) else { continue }
            cost += Double(row.tokens) / 1_000_000 * rate
        }
        return (cost, unpriced)
    }
}
