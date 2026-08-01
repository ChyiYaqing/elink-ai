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
    /// 官方公布价，2026-07-31 核对。
    ///
    /// Anthropic 不单独公布缓存价，按其规则推导：缓存读 0.1×input，
    /// 缓存写取 5 分钟 TTL 的 1.25×input（1 小时 TTL 是 2×，日志里区分不出来，
    /// 取常用的那档）。OpenAI 则是逐档公布的原值。
    ///
    /// claude-sonnet-5 用的是标准价 3/15。它到 2026-08-31 前有 2/10 的优惠价，
    /// 这里不内置：优惠一过标准价自动正确，期间会略微高估。要按优惠价算就用
    /// pricing.json 覆盖。
    static let builtIn: [String: ModelPricing] = [
        "claude-fable-5": ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-opus-5": ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-5": ModelPricing(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "gpt-5.6-sol": ModelPricing(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25),
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
