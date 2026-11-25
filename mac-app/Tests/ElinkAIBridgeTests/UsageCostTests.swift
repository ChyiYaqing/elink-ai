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
            // sonnet 输入 100 万 = $2
            row(day: today, model: "claude-sonnet-5", category: "input", tokens: 1_000_000),
            // opus 缓存读 100 万 = $0.5
            row(day: today, model: "claude-opus-5", category: "cache_read", tokens: 1_000_000),
        ]
        let result = UsageStats.costTotal(rows: rows, range: .day, now: now,
                                          table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 52.5, accuracy: 0.000_001)
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

    /// 卡片上的两行成本：今日只数今天，近 30 天含今天、不含第 31 天。
    func testCostSummaryCoversTodayAndTheTrailingThirtyDays() {
        let today = StatusService.dayKey(now)
        let calendar = StatusService.aggregationCalendar
        let dayKey = { (offset: Int) in
            StatusService.dayKey(calendar.date(byAdding: .day, value: offset, to: self.now)!)
        }
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: dayKey(-29), model: "claude-opus-5", category: "input", tokens: 2_000_000),
            row(day: dayKey(-30), model: "claude-opus-5", category: "input", tokens: 4_000_000),
        ]
        let summary = UsageStats.costSummary(rows: rows, now: now, table: Pricing.builtIn)
        XCTAssertEqual(summary.todayCost, 5, accuracy: 0.000_001)
        XCTAssertEqual(summary.todayTokens, 1_000_000)
        XCTAssertEqual(summary.monthCost, 15, accuracy: 0.000_001)
        XCTAssertEqual(summary.monthTokens, 3_000_000, "窗口外那 4M 不该混进来")
        XCTAssertFalse(summary.hasUnpriced)
    }

    /// 没有定价的模型静静地不计入金额，总额就会偏低而毫无征兆——必须报出来。
    func testCostSummaryFlagsUnpricedModels() {
        let today = StatusService.dayKey(now)
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 1_000_000),
            row(day: today, model: "some-unreleased-model", category: "input", tokens: 9_000_000),
        ]
        let summary = UsageStats.costSummary(rows: rows, now: now, table: Pricing.builtIn)
        XCTAssertEqual(summary.todayCost, 5, accuracy: 0.000_001)
        XCTAssertEqual(summary.todayTokens, 10_000_000, "token 是数得出来的，只有金额算不出")
        XCTAssertTrue(summary.hasUnpriced)
    }

    /// 一条用量都没有时卡片不该出现一整块「$0」。
    func testEmptyCostSummaryIsRecognisable() {
        XCTAssertTrue(UsageStats.costSummary(rows: [], now: now, table: Pricing.builtIn).isEmpty)
    }

    /// 额外用量的币种照接口给的显示：写死 $ 会把欧元额度说成美元额度。
    func testMoneyFollowsTheReportedCurrency() {
        XCTAssertEqual(UsageFormat.money(10.3), "$10.30")
        XCTAssertEqual(UsageFormat.money(2_000, currency: "USD"), "$2000")
        XCTAssertEqual(UsageFormat.money(10.3, currency: "EUR"), "€10.30")
        XCTAssertEqual(UsageFormat.money(10.3, currency: "SEK"), "10.30 SEK")
    }

    /// 「已用 / 上限」必须同精度：`$10.30 / $100` 读起来像哪一边算错了。
    /// 这一对是真实扣款额，不是折算估值，所以两边都保留分位。
    func testMoneyPairKeepsBothSidesAtTheSamePrecision() {
        XCTAssertEqual(UsageFormat.amountPair(10.3, 100, unit: "USD"), "$10.30 / $100.00")
        XCTAssertEqual(UsageFormat.amountPair(0, 2_000, unit: "USD"), "$0.00 / $2000.00")
    }

    /// 桥接出去的今日成本：与并排的 token 数出自同一份分类明细，当天还没落盘
    /// 时也对得上。一条明细都没有时是 nil 而不是 0 ——「今天没用」和「算不出来」
    /// 在屏幕上必须长得不一样。
    func testTodayCostTravelsWithTheTokensItWasDerivedFrom() {
        let usage = [
            "claude-opus-5": ["input": 1_000_000, "output": 200_000],
            "some-unreleased-model": ["input": 5_000_000],
        ]
        let result = StatusService.todayCost(usage, prices: Pricing.builtIn)
        XCTAssertEqual(try XCTUnwrap(result.cost), 10, accuracy: 0.000_001)
        XCTAssertEqual(result.unpriced, ["some-unreleased-model"])

        let empty = StatusService.todayCost([:], prices: Pricing.builtIn)
        XCTAssertNil(empty.cost)
        XCTAssertTrue(empty.unpriced.isEmpty)
    }

    /// 小额要看得见分位，大额取整更好读
    func testCostTextKeepsCentsOnlyWhenTheyMatter() {
        XCTAssertEqual(UsageStats.costText(0.42), "$0.42")
        XCTAssertEqual(UsageStats.costText(53.5), "$53.50")
        XCTAssertEqual(UsageStats.costText(1234.56), "$1235")
    }

    func testCacheEfficiencyComputesHitRateAndNetSavings() throws {
        let today = StatusService.dayKey(now)
        // claude-opus-5: input=$5/M, cache_read=$0.5/M (省 $4.5/M), cache_write=$6.25/M (溢价 $1.25/M)
        let rows = [
            row(day: today, model: "claude-opus-5", category: "input", tokens: 200_000),
            row(day: today, model: "claude-opus-5", category: "cache_write", tokens: 300_000),
            row(day: today, model: "claude-opus-5", category: "cache_read", tokens: 1_500_000),
            row(day: today, model: "claude-opus-5", category: "output", tokens: 100_000),
        ]
        let eff = try XCTUnwrap(UsageStats.cacheEfficiency(rows: rows, range: .day, now: now,
                                                           table: Pricing.builtIn))
        // 1.5M / (0.2M + 0.3M + 1.5M) = 75%
        XCTAssertEqual(eff.hitRate, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(eff.cacheReadTokens, 1_500_000)
        // 净节省 = 1.5 * 4.5 - 0.3 * 1.25 = 6.75 - 0.375 = 6.375
        XCTAssertEqual(eff.savedCost, 6.375, accuracy: 0.000_001)

        // 写入溢价超过读取折扣时，净节省归零（绝不虚报省钱）
        let writeHeavy = [
            row(day: today, model: "claude-opus-5", category: "cache_write", tokens: 1_000_000),
            row(day: today, model: "claude-opus-5", category: "cache_read", tokens: 100_000),
        ]
        let heavyEff = try XCTUnwrap(UsageStats.cacheEfficiency(rows: writeHeavy, range: .day, now: now,
                                                                table: Pricing.builtIn))
        XCTAssertEqual(heavyEff.savedCost, 0, accuracy: 0.000_001)

        // 某模型自定义 cacheRead 高于 input 时应按带符号价差抵消其他模型折扣，仅最终合计截零
        let customTable: [String: ModelPricing] = [
            "good": ModelPricing(input: 5, output: 10, cacheRead: 1, cacheWrite: 5),   // 1M 省 $4
            "bad": ModelPricing(input: 5, output: 10, cacheRead: 10, cacheWrite: 5),   // 1M 亏 $5
        ]
        let mixedSigned = [
            row(day: today, model: "good", category: "cache_read", tokens: 1_000_000),
            row(day: today, model: "bad", category: "cache_read", tokens: 1_000_000),
        ]
        let signedEff = try XCTUnwrap(UsageStats.cacheEfficiency(rows: mixedSigned, range: .day, now: now,
                                                                 table: customTable))
        XCTAssertEqual(signedEff.savedCost, 0, accuracy: 0.000_001)

        // 没有缓存读取时返回 nil
        let noCache = [row(day: today, model: "claude-opus-5", category: "input", tokens: 500_000)]
        XCTAssertNil(UsageStats.cacheEfficiency(rows: noCache, range: .day, now: now,
                                                table: Pricing.builtIn))
    }

    func testYearlyHeatmapAlignsWeeksAndAssignsIntensityLevels() {
        let calendar = StatusService.aggregationCalendar
        let day = { (offset: Int) in
            StatusService.dayKey(calendar.date(byAdding: .day, value: offset, to: self.now)!)
        }
        let rows = [
            DailyModelUsage(day: day(0), provider: "claude", model: "claude-opus-5", tokens: 1_000_000),
            DailyModelUsage(day: day(-1), provider: "claude", model: "claude-opus-5", tokens: 600_000),
            DailyModelUsage(day: day(-2), provider: "claude", model: "claude-opus-5", tokens: 300_000),
            DailyModelUsage(day: day(-3), provider: "claude", model: "claude-opus-5", tokens: 100_000),
        ]
        let weeks = UsageStats.heatmapWeeks(rows: rows, now: now)
        XCTAssertFalse(weeks.isEmpty)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        let inRange = weeks.flatMap { $0 }.filter(\.isInRange)
        XCTAssertEqual(inRange.count, 366)
        let byID = Dictionary(uniqueKeysWithValues: inRange.map { ($0.id, $0) })
        XCTAssertEqual(byID[day(0)]?.level, 4)
        XCTAssertEqual(byID[day(-1)]?.level, 3)
        XCTAssertEqual(byID[day(-2)]?.level, 2)
        XCTAssertEqual(byID[day(-3)]?.level, 1)
        XCTAssertEqual(byID[day(-4)]?.level, 0)
    }
}
