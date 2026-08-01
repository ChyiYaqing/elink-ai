import XCTest
@testable import ElinkAIBridge

/// 统计面板上的金额折算。
final class UsageCostTests: XCTestCase {
    private let now = StatusService.aggregationCalendar.date(
        from: DateComponents(year: 2026, month: 7, day: 31, hour: 12)
    )!

    private func row(day: String, model: String, category: String, tokens: Int)
        -> ModelCategoryUsage {
        ModelCategoryUsage(day: day, provider: "claude", model: model,
                           category: category, tokens: tokens)
    }

    func testDayRangeCountsOnlyToday() {
        let today = StatusService.dayKey(now)
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: "2026-07-01", model: "claude-opus-5", category: "input", tokens: 9_000_000),
        ]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now,
                                          table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 5, accuracy: 0.000_001)
    }

    /// 金额与 token 分类必须框住同一批天，否则面板上两个数会对不上
    func testCostWindowMatchesCategoryWindow() {
        for range in StatsRange.allCases {
            let inWindow = UsageStats.windowFilter(range: range, now: now)
            let today = StatusService.dayKey(now)
            XCTAssertTrue(inWindow(today), "\(range) 应当包含今天")
            XCTAssertFalse(inWindow("2019-01-01"), "\(range) 不应包含七年前")
        }
    }

    /// 不同模型不同分类各按各的单价，不能用一个混合均价糊过去
    func testEachModelAndCategoryUsesItsOwnRate() {
        let today = StatusService.dayKey(now)
        let rows = [
            // fable 输出 100 万 = $50
            row(day: today, model: "claude-fable-5", category: "output", tokens: 1_000_000),
            // sonnet 输入 100 万 = $3
            row(day: today, model: "claude-sonnet-5", category: "input", tokens: 1_000_000),
            // opus 缓存读 100 万 = $0.5
            row(day: today, model: "claude-opus-5", category: "cache_read", tokens: 1_000_000),
        ]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now,
                                          table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 53.5, accuracy: 0.000_001)
        XCTAssertTrue(result.unpriced.isEmpty)
    }

    /// 无定价模型要被点名，不能悄悄当 0 计入总额
    func testUnpricedModelsAreSurfacedNotSilentlyDropped() {
        let today = StatusService.dayKey(now)
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: today, model: "codex-auto-review", category: "input", tokens: 5_000_000),
            row(day: today, model: "<synthetic>", category: "input", tokens: 1_000),
        ]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now,
                                          table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 5, accuracy: 0.000_001)
        XCTAssertEqual(result.unpriced, ["codex-auto-review", "<synthetic>"])
    }

    func testEmptyRowsCostNothingAndFlagNothing() {
        let result = UsageStats.costTotal(rows: [], range: .week, now: now,
                                          table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 0)
        XCTAssertTrue(result.unpriced.isEmpty)
    }

    /// 小额要看得见分位，大额取整更好读
    func testCostTextKeepsCentsOnlyWhenTheyMatter() {
        XCTAssertEqual(UsageStats.costText(0.42), "$0.42")
        XCTAssertEqual(UsageStats.costText(53.5), "$53.50")
        XCTAssertEqual(UsageStats.costText(1234.56), "$1235")
    }
}
