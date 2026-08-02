import XCTest
@testable import ElinkAIBridge

/// 模型×分类 交叉维度的聚合与落库。这一维是金额折算的唯一数据源：
/// 单价既随模型变也随分类变，原有的两张单维表都还原不出来。
final class ModelCategoryUsageTests: XCTestCase {
    private func store(_ name: String = UUID().uuidString) -> (UsageStore, String) {
        let path = NSTemporaryDirectory() + "elink-modelcat-\(name).db"
        try? FileManager.default.removeItem(atPath: path)
        return (UsageStore(path: path), path)
    }

    private let epochDay = "1970-01-01"

    // MARK: - Claude 聚合

    func testClaudeCrossTotalsKeepModelAndCategoryTogether() {
        let accumulator = StatusService.ClaudeUsageAccumulator()
        accumulator.add(lines: [
            #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"a","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#,
            #"{"timestamp":"1970-01-01T00:21:00.000Z","uuid":"b","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":7,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ])

        let totals = accumulator.dailyModelCategoryTotals()
        XCTAssertEqual(totals[epochDay]?["claude-opus-5"],
                       ["input": 10, "output": 2, "cache_write": 3, "cache_read": 5])
        XCTAssertEqual(totals[epochDay]?["claude-sonnet-5"], ["input": 7, "output": 1])
    }

    /// 交叉表按分类求和必须等于原有的单维分类表，否则两处数字会对不上
    func testClaudeCrossTotalsReconcileWithCategoryTotals() {
        let accumulator = StatusService.ClaudeUsageAccumulator()
        accumulator.add(lines: [
            #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"a","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#,
            #"{"timestamp":"1970-01-01T00:21:00.000Z","uuid":"b","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":7,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ])

        var flattened: [String: Int] = [:]
        for (_, categories) in accumulator.dailyModelCategoryTotals()[epochDay] ?? [:] {
            for (category, tokens) in categories { flattened[category, default: 0] += tokens }
        }
        XCTAssertEqual(flattened, accumulator.dailyCategoryTotals()[epochDay])
    }

    /// 同一模型跨多条消息要累加，不能后一条覆盖前一条
    func testSameModelAccumulatesAcrossMessages() {
        let accumulator = StatusService.ClaudeUsageAccumulator()
        accumulator.add(lines: [
            #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"a","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            #"{"timestamp":"1970-01-01T00:21:00.000Z","uuid":"b","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ])
        XCTAssertEqual(accumulator.dailyModelCategoryTotals()[epochDay]?["claude-opus-5"],
                       ["input": 15])
    }

    // MARK: - Codex 聚合

    func testCodexCrossTotalsSplitReasoningFromOutput() {
        let events = StatusService.codexUsageEvents(lines: [
            #"{"timestamp":"1970-01-01T00:20:00.000Z","type":"event_msg","payload":{"model":"gpt-5.6-sol","type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140}}}}"#,
        ])
        let totals = StatusService.bucketCodexModelCategories(events, dayKey: StatusService.dayKey)
        // cached ⊆ input、reasoning ⊆ output，扣掉重叠后四类互不相交
        XCTAssertEqual(totals[epochDay]?["gpt-5.6-sol"],
                       ["input": 40, "cache_read": 60, "output": 30, "reasoning": 10])
    }

    // MARK: - 落库

    func testModelCategoryUsageRoundTripsThroughTheStore() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.recordModelCategories(
            day: epochDay, provider: "claude",
            usage: ["claude-opus-5": ["input": 10, "output": 2],
                    "claude-sonnet-5": ["input": 7]],
            expectedBucketTimeZone: nil
        )

        let rows = store.modelCategoryUsage(provider: "claude", since: epochDay)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first { $0.model == "claude-opus-5" && $0.category == "output" }?.tokens, 2)
        XCTAssertEqual(rows.first { $0.model == "claude-sonnet-5" }?.tokens, 7)
    }

    /// 覆盖写：重写同一天必须换掉旧值而不是叠加
    func testRewritingADayReplacesRatherThanAccumulates() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.recordModelCategories(day: epochDay, provider: "claude",
                                    usage: ["claude-opus-5": ["input": 10]],
                                    expectedBucketTimeZone: nil)
        store.recordModelCategories(day: epochDay, provider: "claude",
                                    usage: ["claude-opus-5": ["input": 25]],
                                    expectedBucketTimeZone: nil)

        let rows = store.modelCategoryUsage(provider: "claude", since: epochDay)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tokens, 25)
    }

    /// 空集意味着「这次没读到日志」，不能把已有的一天清空
    func testEmptyUsageDoesNotWipeAnExistingDay() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.recordModelCategories(day: epochDay, provider: "claude",
                                    usage: ["claude-opus-5": ["input": 10]],
                                    expectedBucketTimeZone: nil)
        store.recordModelCategories(day: epochDay, provider: "claude", usage: [:],
                                    expectedBucketTimeZone: nil)

        XCTAssertEqual(store.modelCategoryUsage(provider: "claude", since: epochDay).count, 1)
    }

    /// provider 之间互不干扰
    func testProvidersAreStoredSeparately() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.recordModelCategories(day: epochDay, provider: "claude",
                                    usage: ["claude-opus-5": ["input": 10]],
                                    expectedBucketTimeZone: nil)
        store.recordModelCategories(day: epochDay, provider: "codex",
                                    usage: ["gpt-5.6-sol": ["input": 99]],
                                    expectedBucketTimeZone: nil)

        XCTAssertEqual(store.modelCategoryUsage(provider: "claude", since: epochDay).count, 1)
        XCTAssertEqual(store.modelCategoryUsage(provider: "codex", since: epochDay)[0].tokens, 99)
    }

    // MARK: - 历史回填

    /// 回填要覆盖多天，否则周/月/年金额只算得到最近几天。
    /// 现象是 Day 和 Week 显示同一个金额，而它们上方的 token 数差着好几倍。
    func testBackfillCoversEveryScannedDay() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let filled = store.backfillModelCategories(expectedTimeZone: nil, usage: [
            "claude": [
                "2026-07-30": ["claude-opus-5": ["input": 1_000_000]],
                "2026-07-31": ["claude-opus-5": ["output": 1_000_000]],
                "2026-08-01": ["claude-opus-5": ["cache_read": 1_000_000]],
            ],
        ])
        XCTAssertTrue(filled)

        let rows = store.modelCategoryUsage(provider: "claude", since: "2026-07-30")
        XCTAssertEqual(Set(rows.map(\.day)), ["2026-07-30", "2026-07-31", "2026-08-01"])
        // 1M input $5 + 1M output $25 + 1M cache_read $0.5
        let total = Pricing.total(rows: rows, table: Pricing.builtIn)
        XCTAssertEqual(total.cost, 30.5, accuracy: 0.000_001)
    }

    /// 回填是整个 provider 重建：改过归属的天不能既留旧行又加新行
    func testBackfillReplacesRatherThanAccumulates() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.backfillModelCategories(expectedTimeZone: nil, usage: [
            "claude": ["2026-07-30": ["claude-opus-5": ["input": 1_000_000]]],
        ])
        store.backfillModelCategories(expectedTimeZone: nil, usage: [
            "claude": ["2026-07-31": ["claude-opus-5": ["input": 2_000_000]]],
        ])

        let rows = store.modelCategoryUsage(provider: "claude", since: "2026-07-01")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].day, "2026-07-31")
    }

    /// 时区标记对不上就整批放弃，避免把别的时区的分桶混进来
    func testBackfillRefusesAMismatchedTimeZone() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // 新库的时区标记是 nil，传一个具体时区即为不匹配
        XCTAssertFalse(store.backfillModelCategories(expectedTimeZone: "Asia/Shanghai", usage: [
            "claude": ["2026-07-30": ["claude-opus-5": ["input": 1_000_000]]],
        ]))
        XCTAssertTrue(store.modelCategoryUsage(provider: "claude", since: "2026-07-01").isEmpty)
    }

    /// 回填必须同时补进集群表：读路径在组了集群时走的是那张表。
    /// 只写本机表的话，本机今天没用过的 provider（比如今天没跑 codex）
    /// 会在所有区间里都没有金额，哪怕历史用量摆在那里。
    func testBackfillAlsoFeedsTheClusterReadPath() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        // 集群口径要 JOIN 快照，先让这一天有一份本机快照
        store.record(day: "2026-07-18", provider: "codex",
                     models: ["gpt-5.6-sol": 1_000_000], expectedBucketTimeZone: nil)

        store.backfillModelCategories(expectedTimeZone: nil, usage: [
            "codex": ["2026-07-18": ["gpt-5.6-sol": ["input": 1_000_000]]],
        ])

        // 走 UI 实际使用的入口（集群启用 -> 集群表）
        let rows = store.modelCategoryUsage(provider: "codex", since: "2026-07-01")
        XCTAssertEqual(rows.count, 1, "回填的历史必须能从集群口径读到")
        XCTAssertEqual(rows[0].tokens, 1_000_000)
        XCTAssertEqual(Pricing.total(rows: rows, table: Pricing.builtIn).cost, 5,
                       accuracy: 0.000_001)
    }

    // MARK: - 端到端折算

    /// 存进去的用量能按官方价折算出金额，这是整条链路的最终目的
    func testStoredUsageConvertsToCost() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.recordModelCategories(
            day: epochDay, provider: "claude",
            // 100 万 input + 100 万 output = 5 + 25
            usage: ["claude-opus-5": ["input": 1_000_000, "output": 1_000_000]],
            expectedBucketTimeZone: nil
        )

        let rows = store.modelCategoryUsage(provider: "claude", since: epochDay)
        let result = Pricing.total(rows: rows, table: Pricing.builtIn)
        XCTAssertEqual(result.cost, 30, accuracy: 0.000_001)
        XCTAssertTrue(result.unpriced.isEmpty)
    }
}
