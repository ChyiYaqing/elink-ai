import XCTest
@testable import ElinkAIBridge

final class PricingTests: XCTestCase {
    private func temporaryPath(_ name: String = UUID().uuidString) -> String {
        NSTemporaryDirectory() + "elink-pricing-\(name).json"
    }

    /// 官方公布价，改动内置表时这里必须跟着改——这是价格写错时唯一会响的地方
    func testBuiltInRatesMatchPublishedPricing() {
        let table = Pricing.builtIn
        XCTAssertEqual(table["claude-fable-5"],
                       ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5))
        XCTAssertEqual(table["claude-opus-5"],
                       ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25))
        XCTAssertEqual(table["claude-sonnet-5"],
                       ModelPricing(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75))
        XCTAssertEqual(table["gpt-5.6-sol"],
                       ModelPricing(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25))
    }

    /// 缓存读远比输入便宜，缓存写更贵。分类单价搞混会让总额差一个数量级
    func testCategoryRatesAreDistinct() {
        let opus = Pricing.builtIn["claude-opus-5"]!
        XCTAssertEqual(opus.rate(for: "input"), 5)
        XCTAssertEqual(opus.rate(for: "output"), 25)
        XCTAssertEqual(opus.rate(for: "cache_read"), 0.5)
        XCTAssertEqual(opus.rate(for: "cache_write"), 6.25)
        XCTAssertNil(opus.rate(for: "nonsense"))
    }

    /// Codex 的 reasoning token 按输出价计费，不能漏算成 0
    func testReasoningIsBilledAsOutput() {
        let sol = Pricing.builtIn["gpt-5.6-sol"]!
        XCTAssertEqual(sol.rate(for: "reasoning"), sol.output)

        let cost = Pricing.cost(model: "gpt-5.6-sol",
                                categories: ["reasoning": 1_000_000],
                                table: Pricing.builtIn)
        XCTAssertEqual(cost ?? 0, 30, accuracy: 0.000_001)
    }

    func testCostSumsCategoriesAtTheirOwnRates() {
        // 100 万 input + 100 万 output + 100 万 cache_read = 5 + 25 + 0.5
        let cost = Pricing.cost(model: "claude-opus-5",
                                categories: ["input": 1_000_000,
                                             "output": 1_000_000,
                                             "cache_read": 1_000_000],
                                table: Pricing.builtIn)
        XCTAssertEqual(cost ?? 0, 30.5, accuracy: 0.000_001)
    }

    /// 未知模型返回 nil 而不是 0：算成 0 会让总额看着正常却少一截
    func testUnknownModelHasNoPriceRatherThanZero() {
        XCTAssertNil(Pricing.cost(model: "codex-auto-review",
                                  categories: ["input": 1_000_000],
                                  table: Pricing.builtIn))
        XCTAssertNil(Pricing.cost(model: "<synthetic>",
                                  categories: ["input": 1_000_000],
                                  table: Pricing.builtIn))
    }

    /// 没定价的模型必须被点名带回来，否则调用方会把残缺的总额当成全部
    func testTotalReportsUnpricedModelsInsteadOfSwallowingThem() {
        let rows = [
            ModelCategoryUsage(day: "2026-07-31", provider: "claude",
                               model: "claude-opus-5", category: "input", tokens: 1_000_000),
            ModelCategoryUsage(day: "2026-07-31", provider: "codex",
                               model: "codex-auto-review", category: "input", tokens: 9_000_000),
        ]
        let result = Pricing.total(rows: rows, table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 5, accuracy: 0.000_001)
        XCTAssertEqual(result.unpriced, ["codex-auto-review"])
    }

    func testOverrideFileReplacesBuiltInRate() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let json = """
        {"claude-sonnet-5": {"input": 2, "output": 10, "cache_read": 0.2, "cache_write": 2.5}}
        """
        try? json.write(toFile: path, atomically: true, encoding: .utf8)

        let table = Pricing.table(overridePath: path)
        // 覆盖生效
        XCTAssertEqual(table["claude-sonnet-5"],
                       ModelPricing(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5))
        // 未被覆盖的仍是内置价
        XCTAssertEqual(table["claude-opus-5"], Pricing.builtIn["claude-opus-5"])
    }

    /// 覆盖表要能给新模型定价，否则新模型出来就得等发版
    func testOverrideCanPriceAModelTheBuiltInTableDoesNotKnow() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try? #"{"gpt-5.6-terra": {"input": 2, "output": 12}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let table = Pricing.table(overridePath: path)
        XCTAssertEqual(table["gpt-5.6-terra"]?.output, 12)
        // 缺省的缓存字段按 0 计，而不是让整条记录失效
        XCTAssertEqual(table["gpt-5.6-terra"]?.cacheRead, 0)
    }

    /// 覆盖文件坏了要退回内置价，不能让整个用量面板打不开
    func testBrokenOverrideFileFallsBackToBuiltIn() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try? "{ this is not json".write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(Pricing.table(overridePath: path)["claude-opus-5"],
                       Pricing.builtIn["claude-opus-5"])
    }

    func testMissingOverrideFileIsNotAnError() {
        XCTAssertTrue(Pricing.loadOverrides(path: temporaryPath("absent")).isEmpty)
        XCTAssertEqual(Pricing.table(overridePath: temporaryPath("absent")).count,
                       Pricing.builtIn.count)
    }
}
