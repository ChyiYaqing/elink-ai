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

    /// 复现报告的问题：Day 和 Week 显示同一个金额。
    /// 根因是分类表只有今天，而 token 总量是回填过的——窗口一放大，
    /// 金额纹丝不动。回填补上历史后，Week 必须严格大于 Day。
    func testWeekCostExceedsDayOnceHistoryIsBackfilled() {
        let today = StatusService.dayKey(now)
        let earlier = StatusService.dayKey(now.addingTimeInterval(-3 * 86_400))
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: earlier, model: "claude-opus-5", category: "input", tokens: 4_000_000),
        ]
        let day = UsageStats.costTotal(rows: rows, range: .day, now: now, table: Pricing.builtIn)
        let week = UsageStats.costTotal(rows: rows, range: .week, now: now, table: Pricing.builtIn)

        XCTAssertEqual(day.cost, 5, accuracy: 0.000_001)
        XCTAssertEqual(week.cost, 25, accuracy: 0.000_001)
        XCTAssertGreaterThan(week.cost, day.cost, "回填后更大的窗口必须算出更大的金额")
    }

    /// 分类缺席时金额会静默偏低，必须靠覆盖率暴露出来
    func testCoverageRevealsAPartialCost() {
        let today = StatusService.dayKey(now)
        let rows = [row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000)]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now, table: Pricing.builtIn)
        // 窗口里其实有 4M token，只有 1M 有分类明细
        XCTAssertEqual(
            UsageStats.costCoverage(pricedTokens: result.pricedTokens, windowTokens: 4_000_000),
            0.25, accuracy: 0.000_001
        )
        // 全部都有明细时是满覆盖
        XCTAssertEqual(
            UsageStats.costCoverage(pricedTokens: result.pricedTokens, windowTokens: 1_000_000),
            1, accuracy: 0.000_001
        )
    }

    /// 没有 token 的窗口不该显示成「覆盖 0%」
    func testCoverageOfAnEmptyWindowIsComplete() {
        XCTAssertEqual(UsageStats.costCoverage(pricedTokens: 0, windowTokens: 0), 1)
    }

    /// 无定价的模型不计入已覆盖 token，否则覆盖率会假装完整
    func testUnpricedTokensDoNotCountAsCovered() {
        let today = StatusService.dayKey(now)
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: today, model: "codex-auto-review", category: "input", tokens: 3_000_000),
        ]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now, table: Pricing.builtIn)
        XCTAssertEqual(result.pricedTokens, 1_000_000)
        XCTAssertEqual(
            UsageStats.costCoverage(pricedTokens: result.pricedTokens, windowTokens: 4_000_000),
            0.25, accuracy: 0.000_001
        )
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
