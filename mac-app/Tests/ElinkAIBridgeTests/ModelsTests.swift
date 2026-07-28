import XCTest
import SQLite3
@testable import ElinkAIBridge

final class ModelsTests: XCTestCase {
    // 部分断言依赖中文文案；语言默认跟随系统，这里固定为中文保证在英文系统的 CI 上稳定
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    func testAppLanguageSelectionDrivesTr() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .english)
        XCTAssertEqual(tr("中文文案", "English copy"), "English copy")

        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .chinese)
        XCTAssertEqual(tr("中文文案", "English copy"), "中文文案")
    }

    func testSnapshotHasVersionedShape() throws {
        var snapshot = BridgeSnapshot()
        snapshot.claude.state = "working"
        snapshot.claude.primary.percent = 42
        snapshot.claude.modelUsageToday = [ModelUsage(model: "claude-sonnet", tokens: 1200)]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        let claude = try XCTUnwrap(object["claude"] as? [String: Any])
        XCTAssertEqual(claude["five_hour_pct"] as? Double, 42)
        XCTAssertEqual(claude["provider_usage_cached"] as? Bool, false)
        let models = try XCTUnwrap(claude["model_usage_today"] as? [[String: Any]])
        XCTAssertEqual(models.first?["model"] as? String, "claude-sonnet")
        XCTAssertEqual(models.first?["tokens"] as? Int, 1200)
        let cluster = try XCTUnwrap(object["cluster"] as? [String: Any])
        XCTAssertEqual(cluster["enabled"] as? Bool, false)
        XCTAssertEqual(cluster["node_count"] as? Int, 1)
    }

    func testAggregationDayBoundaryStaysConsistentWithDayKeyAcrossTimeZones() {
        StatusService.setAggregationTimeZone("Pacific/Kiritimati")
        defer { StatusService.setAggregationTimeZone(nil) }
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let startOfDay = StatusService.startOfAggregationDay(reference)
        let key = StatusService.dayKey(reference)
        XCTAssertEqual(StatusService.dayKey(startOfDay), key)
        XCTAssertNotEqual(StatusService.dayKey(startOfDay.addingTimeInterval(-1)), key)
    }

    func testCapturedDayKeyDoesNotFollowLaterGlobalTimeZoneChanges() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let fixedDayKey = StatusService.dayKeyMaker(utc)
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = fixedDayKey(reference)

        StatusService.setAggregationTimeZone("Pacific/Kiritimati")
        defer { StatusService.setAggregationTimeZone(nil) }

        XCTAssertEqual(fixedDayKey(reference), expected)
        XCTAssertNotEqual(StatusService.dayKey(reference), expected)
    }

    func testUsageMaintenanceRemainsNeededWhileStoredMarkerLagsCurrentTimeZone() {
        let path = NSTemporaryDirectory() + "elink-maintenance-retry-\(UUID().uuidString).db"
        defer {
            StatusService.setAggregationTimeZone(nil)
            try? FileManager.default.removeItem(atPath: path)
        }
        let store = UsageStore(path: path)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "UTC",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(claude: [:], codex: [:])
        ), .applied)
        // 解析器版本也已登记，否则版本门控会让维护始终显示待执行
        XCTAssertTrue(store.mergeBackfillTotals(
            expectedTimeZone: "UTC",
            totals: UsageHistoryTotals(claude: [:], codex: [:]),
            exact: true,
            recordingParserVersion: StatusService.usageParserVersion
        ))
        let service = StatusService(usage: UsageFetcher(cacheStore: store), store: store)

        StatusService.setAggregationTimeZone("UTC")
        XCTAssertFalse(service.usageMaintenanceNeeded())
        StatusService.setAggregationTimeZone("Asia/Singapore")
        XCTAssertTrue(service.usageMaintenanceNeeded())
        XCTAssertTrue(StatusService.shouldRunUsageMaintenance(
            applied: "Asia/Singapore", current: "Asia/Singapore", retryPending: true
        ))
    }

    func testJSONLFileScanDistinguishesMissingRootFromInvalidRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elink-jsonl-root-\(UUID().uuidString)")
        let missing = root.appendingPathExtension("missing")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(try XCTUnwrap(StatusService.jsonlFiles(at: missing)).isEmpty)
        try "not a directory".write(to: root, atomically: true, encoding: .utf8)
        XCTAssertNil(StatusService.jsonlFiles(at: root))
    }

    func testKnownRebucketPlanPreservesResidueWhenTargetDayHasMoreLogUsage() {
        let plan = UsageStore.knownRebucketPlan(
            stored: ["2026-07-14": ["sonnet": 150]],
            oldExplained: ["2026-07-14": ["sonnet": 100]],
            targetTotals: ["2026-07-14": ["sonnet": 200]]
        )

        XCTAssertEqual(plan, ["2026-07-14": ["sonnet": 250]])
    }

    func testLegacyRebucketPlanMovesKnownLogsWithoutDoubleCountingAndPreservesTotal() {
        let plan = UsageStore.legacyRebucketPlan(
            stored: ["2026-07-14": ["sonnet": 110]],
            targetTotals: ["2026-07-15": ["sonnet": 10]]
        )

        XCTAssertEqual(plan, [
            "2026-07-14": ["sonnet": 100],
            "2026-07-15": ["sonnet": 10],
        ])
    }

    func testSnapshotUsesLatestProviderUsageUpdate() {
        let old = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(StatusService.latestUsageFetchedAt(claude: old, codex: latest), latest)
        XCTAssertEqual(StatusService.latestUsageFetchedAt(claude: latest, codex: nil), latest)
        XCTAssertNil(StatusService.latestUsageFetchedAt(claude: nil, codex: nil))
    }

    func testClaudeUsageIsDeduplicatedAndGroupedByDayAndModel() {
        let first = #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"one","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:01.000Z","uuid":"two","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let second = #"{"timestamp":"1970-01-01T00:20:02.000Z","uuid":"three","message":{"id":"msg-2","model":"claude-b","usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let nextDay = #"{"timestamp":"1970-01-03T00:20:00.000Z","uuid":"four","message":{"id":"msg-3","model":"claude-a","usage":{"input_tokens":4,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

        let accumulator = StatusService.ClaudeUsageAccumulator()
        accumulator.add(lines: [first, duplicate, second])
        // 会话续写会把同一消息复制到另一个文件，跨文件也要去重
        accumulator.add(lines: [duplicate, nextDay])

        let dayOne = StatusService.dayKey(Date(timeIntervalSince1970: 1_200))
        let dayTwo = StatusService.dayKey(Date(timeIntervalSince1970: 2 * 86_400 + 1_200))
        XCTAssertEqual(accumulator.dailyTotals(), [
            dayOne: ["claude-a": 20, "claude-b": 7],
            dayTwo: ["claude-a": 4],
        ])
    }

    func testCodexUsageFollowsModelChangesAndSkipsDuplicateCounts() {
        let modelA = #"{"timestamp":"1970-01-01T00:20:00.000Z","type":"turn_context","payload":{"model":"gpt-a"}}"#
        let countA = #"{"timestamp":"1970-01-01T00:20:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"total_tokens":10}}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"total_tokens":10}}}}"#
        let modelB = #"{"timestamp":"1970-01-01T00:20:03.000Z","type":"turn_context","payload":{"model":"gpt-b"}}"#
        let countB = #"{"timestamp":"1970-01-01T00:20:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":30},"last_token_usage":{"total_tokens":20}}}}"#
        let countNextDay = #"{"timestamp":"1970-01-03T00:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":45},"last_token_usage":{"total_tokens":15}}}}"#

        let daily = StatusService.codexDailyUsage(
            lines: [modelA, countA, duplicate, modelB, countB, countNextDay])

        let dayOne = StatusService.dayKey(Date(timeIntervalSince1970: 1_200))
        let dayTwo = StatusService.dayKey(Date(timeIntervalSince1970: 2 * 86_400 + 1_200))
        XCTAssertEqual(daily, [
            dayOne: ["gpt-a": 10, "gpt-b": 20],
            dayTwo: ["gpt-b": 15],
        ])
    }

    func testCodexLeadingTokenCountsBelongToFirstDeclaredModel() {
        // 真实 subagent 日志顺序：token_count 先出现，turn_context 的模型声明在后
        let leadingCount = #"{"timestamp":"1970-01-01T00:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":40},"last_token_usage":{"total_tokens":40}}}}"#
        let anotherLeading = #"{"timestamp":"1970-01-01T00:11:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":70},"last_token_usage":{"total_tokens":30}}}}"#
        let lateModel = #"{"timestamp":"1970-01-01T00:12:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
        let trailingCount = #"{"timestamp":"1970-01-01T00:13:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100},"last_token_usage":{"total_tokens":30}}}}"#

        let daily = StatusService.codexDailyUsage(
            lines: [leadingCount, anotherLeading, lateModel, trailingCount])

        let day = StatusService.dayKey(Date(timeIntervalSince1970: 600))
        XCTAssertEqual(daily, [day: ["gpt-5.6-sol": 100]])
    }

    func testCodexFileWithoutAnyModelStaysUnknown() {
        let count = #"{"timestamp":"1970-01-01T00:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":25},"last_token_usage":{"total_tokens":25}}}}"#

        let daily = StatusService.codexDailyUsage(lines: [count])

        let day = StatusService.dayKey(Date(timeIntervalSince1970: 600))
        XCTAssertEqual(daily, [day: ["unknown": 25]])
    }

    func testExactRebuildReplacesCoveredDaysAndKeepsUncoveredHistory() {
        let stored: DailyUsageTotals = [
            // 日志仍覆盖的一天：旧解析器把 40 记给了 unknown
            "2026-07-18": ["unknown": 40, "gpt-5.6-sol": 60],
            // 日志已删除的一天：无从重算，必须原样保留
            "2026-01-02": ["gpt-old": 500],
        ]
        let recomputed: DailyUsageTotals = [
            "2026-07-18": ["gpt-5.6-sol": 100],
        ]

        XCTAssertEqual(UsageStore.exactRebuildPlan(stored: stored, targetTotals: recomputed), [
            "2026-07-18": ["gpt-5.6-sol": 100],
            "2026-01-02": ["gpt-old": 500],
        ])
    }

    func testMergeBackfillExactModeCleansStaleAttributionAndRecordsParserVersion() {
        let path = NSTemporaryDirectory() + "elink-parser-rebuild-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil, target: "Asia/Singapore",
            oldExplained: nil, targetTotals: UsageHistoryTotals(claude: [:], codex: [:])
        ), .applied)
        store.record(day: "2026-07-18", provider: "codex",
                     models: ["unknown": 40, "gpt-5.6-sol": 60],
                     expectedBucketTimeZone: "Asia/Singapore")

        // 非精确回填：残差规则会把 unknown 40 保留下来
        XCTAssertTrue(store.mergeBackfillTotals(
            expectedTimeZone: "Asia/Singapore",
            totals: UsageHistoryTotals(claude: [:], codex: ["2026-07-18": ["gpt-5.6-sol": 100]])
        ))
        XCTAssertEqual(
            store.usage(provider: "codex", since: "2026-07-18").map { "\($0.model):\($0.tokens)" }.sorted(),
            ["gpt-5.6-sol:100", "unknown:40"]
        )

        // 精确重建：unknown 被清洗，解析器版本在同一事务里登记
        XCTAssertTrue(store.mergeBackfillTotals(
            expectedTimeZone: "Asia/Singapore",
            totals: UsageHistoryTotals(claude: [:], codex: ["2026-07-18": ["gpt-5.6-sol": 100]]),
            exact: true,
            recordingParserVersion: StatusService.usageParserVersion
        ))
        XCTAssertEqual(store.usage(provider: "codex", since: "2026-07-18"), [
            DailyModelUsage(day: "2026-07-18", provider: "codex",
                            model: "gpt-5.6-sol", tokens: 100),
        ])
        XCTAssertEqual(store.usageParserVersion(), StatusService.usageParserVersion)
    }

    func testUsageStoreUpsertsAndQueriesByProviderAndDay() {
        let path = NSTemporaryDirectory() + "elink-usage-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)

        store.record(day: "2026-07-13", provider: "claude",
                     models: ["claude-a": 100, "claude-b": 50], expectedBucketTimeZone: nil)
        store.record(day: "2026-07-14", provider: "claude",
                     models: ["claude-a": 10, "empty": 0], expectedBucketTimeZone: nil)
        store.record(day: "2026-07-14", provider: "codex", models: ["gpt-a": 7],
                     expectedBucketTimeZone: nil)
        store.record(day: "2026-07-14", provider: "claude", models: ["claude-a": 25],
                     expectedBucketTimeZone: nil)

        XCTAssertEqual(store.usage(provider: "claude", since: "2026-07-14"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "claude-a", tokens: 25),
        ])
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01").count, 3)
        XCTAssertEqual(store.usage(provider: "codex", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "codex", model: "gpt-a", tokens: 7),
        ])
    }

    func testRecordHourlyRoundTripAndOverwrite() {
        let path = NSTemporaryDirectory() + "elink-hourly-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)

        store.recordHourly(day: "2026-07-24", provider: "claude",
                           hours: [14: ["claude-a": 7], 9: ["claude-a": 5, "claude-b": 3]],
                           expectedBucketTimeZone: nil)
        XCTAssertEqual(store.hourlyUsage(provider: "claude", day: "2026-07-24"), [
            HourlyModelUsage(day: "2026-07-24", hour: 9, provider: "claude",
                             model: "claude-a", tokens: 5),
            HourlyModelUsage(day: "2026-07-24", hour: 9, provider: "claude",
                             model: "claude-b", tokens: 3),
            HourlyModelUsage(day: "2026-07-24", hour: 14, provider: "claude",
                             model: "claude-a", tokens: 7),
        ])

        // 覆盖语义：整天替换，旧小时行不残留
        store.recordHourly(day: "2026-07-24", provider: "claude",
                           hours: [10: ["claude-a": 4]], expectedBucketTimeZone: nil)
        XCTAssertEqual(store.hourlyUsage(provider: "claude", day: "2026-07-24"), [
            HourlyModelUsage(day: "2026-07-24", hour: 10, provider: "claude",
                             model: "claude-a", tokens: 4),
        ])
        XCTAssertEqual(store.hourlyUsage(provider: "codex", day: "2026-07-24"), [])
    }

    func testRecordHourlyIgnoresEmptySetAndTimeZoneMismatch() {
        let path = NSTemporaryDirectory() + "elink-hourly-guard-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)

        store.recordHourly(day: "2026-07-24", provider: "claude",
                           hours: [8: ["claude-a": 5]], expectedBucketTimeZone: nil)
        let expected = [HourlyModelUsage(day: "2026-07-24", hour: 8, provider: "claude",
                                         model: "claude-a", tokens: 5)]

        // 空集视为日志暂不可读，不清已有数据
        store.recordHourly(day: "2026-07-24", provider: "claude", hours: [:],
                           expectedBucketTimeZone: nil)
        store.recordHourly(day: "2026-07-24", provider: "claude", hours: [8: ["claude-a": 0]],
                           expectedBucketTimeZone: nil)
        XCTAssertEqual(store.hourlyUsage(provider: "claude", day: "2026-07-24"), expected)

        // 分桶时区标记不一致时拒绝写入
        store.recordHourly(day: "2026-07-24", provider: "claude", hours: [9: ["claude-a": 9]],
                           expectedBucketTimeZone: "Asia/Singapore")
        XCTAssertEqual(store.hourlyUsage(provider: "claude", day: "2026-07-24"), expected)
    }

    func testHourKeyMakerAndHourBucketsExtractTargetDay() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let hourKey = StatusService.hourKeyMaker(utc)
        // 2023-11-14 22:13:20 UTC
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(hourKey(reference), "2023-11-14 22")
        XCTAssertEqual(hourKey(reference.addingTimeInterval(-3600)), "2023-11-14 21")
        XCTAssertEqual(hourKey(reference.addingTimeInterval(7200)), "2023-11-15 00")

        let buckets = StatusService.hourBuckets(from: [
            "2023-11-14 21": ["claude-a": 5],
            "2023-11-14 22": ["claude-a": 7, "claude-b": 2],
            "2023-11-15 00": ["claude-a": 9],
        ], day: "2023-11-14")
        XCTAssertEqual(buckets, [21: ["claude-a": 5], 22: ["claude-a": 7, "claude-b": 2]])
    }

    func testRecordCategoriesRoundTripOverwriteAndGuards() {
        let path = NSTemporaryDirectory() + "elink-category-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)

        store.recordCategories(day: "2026-07-24", provider: "claude",
                               categories: ["input": 10, "cache_read": 90, "empty": 0],
                               expectedBucketTimeZone: nil)
        XCTAssertEqual(store.categoryUsage(provider: "claude", since: "2026-07-24"), [
            DailyCategoryUsage(day: "2026-07-24", provider: "claude",
                               category: "cache_read", tokens: 90),
            DailyCategoryUsage(day: "2026-07-24", provider: "claude",
                               category: "input", tokens: 10),
        ])

        // 覆盖语义：整天替换，消失的分类不残留
        store.recordCategories(day: "2026-07-24", provider: "claude",
                               categories: ["output": 7], expectedBucketTimeZone: nil)
        let expected = [DailyCategoryUsage(day: "2026-07-24", provider: "claude",
                                           category: "output", tokens: 7)]
        XCTAssertEqual(store.categoryUsage(provider: "claude", since: "2026-07-24"), expected)

        // 空集与时区不匹配都不动已有数据
        store.recordCategories(day: "2026-07-24", provider: "claude", categories: [:],
                               expectedBucketTimeZone: nil)
        store.recordCategories(day: "2026-07-24", provider: "claude", categories: ["input": 9],
                               expectedBucketTimeZone: "Asia/Singapore")
        XCTAssertEqual(store.categoryUsage(provider: "claude", since: "2026-07-24"), expected)
        XCTAssertEqual(store.categoryUsage(provider: "codex", since: "2026-01-01"), [])
    }

    func testClaudeUsageAccumulatorSplitsTokenCategories() {
        let first = #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"one","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:01.000Z","uuid":"two","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let second = #"{"timestamp":"1970-01-01T00:20:02.000Z","uuid":"three","message":{"id":"msg-2","model":"claude-b","usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

        let accumulator = StatusService.ClaudeUsageAccumulator()
        accumulator.add(lines: [first, duplicate, second])

        let day = StatusService.dayKey(Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(accumulator.dailyCategoryTotals(), [
            day: ["input": 17, "output": 2, "cache_write": 3, "cache_read": 5],
        ])
    }

    func testCodexUsageEventsSplitTokenCategoriesDisjointly() {
        let model = #"{"timestamp":"1970-01-01T00:20:00.000Z","type":"turn_context","payload":{"model":"gpt-a"}}"#
        // cached ⊆ input、reasoning ⊆ output，分类应扣除重叠
        let first = #"{"timestamp":"1970-01-01T00:20:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140}}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140}}}}"#
        // 无 last_token_usage 时按累计值差分
        let cumulativeOnly = #"{"timestamp":"1970-01-01T00:20:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":80,"output_tokens":60,"reasoning_output_tokens":15,"total_tokens":190}}}}"#

        let events = StatusService.codexUsageEvents(
            lines: [model, first, duplicate, cumulativeOnly])

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].tokens, 140)
        XCTAssertEqual(events[0].categories,
                       ["input": 40, "cache_read": 60, "output": 30, "reasoning": 10])
        XCTAssertEqual(events[1].tokens, 50)
        XCTAssertEqual(events[1].categories,
                       ["input": 10, "cache_read": 20, "output": 15, "reasoning": 5])

        let day = StatusService.dayKey(Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(StatusService.bucketCodexCategories(events, dayKey: StatusService.dayKey), [
            day: ["input": 50, "cache_read": 80, "output": 45, "reasoning": 15],
        ])
    }

    func testCategoryTotalsFollowRangeWindows() throws {
        let calendar = StatusService.aggregationCalendar
        let now = Date()
        let today = StatusService.dayKey(now)
        let eightDaysAgo = StatusService.dayKey(
            try XCTUnwrap(calendar.date(byAdding: .day, value: -8, to: now)))
        let rows = [
            DailyCategoryUsage(day: today, provider: "claude", category: "input", tokens: 5),
            DailyCategoryUsage(day: eightDaysAgo, provider: "claude", category: "input", tokens: 7),
        ]

        XCTAssertEqual(UsageStats.categoryTotals(rows: rows, range: .day, now: now),
                       ["input": 5])
        XCTAssertEqual(UsageStats.categoryTotals(rows: rows, range: .week, now: now),
                       ["input": 5])
        XCTAssertEqual(UsageStats.categoryTotals(rows: rows, range: .month, now: now),
                       ["input": 12])
        XCTAssertEqual(UsageStats.categoryTotals(rows: rows, range: .year, now: now),
                       ["input": 12])
    }

    func testHourlyBucketsProduce24BarsWithModelsAtCorrectHours() {
        let buckets = UsageStats.hourlyBuckets(rows: [
            HourlyModelUsage(day: "2026-07-24", hour: 9, provider: "claude",
                             model: "claude-a", tokens: 5),
            HourlyModelUsage(day: "2026-07-24", hour: 9, provider: "claude",
                             model: "claude-b", tokens: 3),
            HourlyModelUsage(day: "2026-07-24", hour: 23, provider: "claude",
                             model: "claude-a", tokens: 4),
        ])
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets.first?.id, "00")
        XCTAssertEqual(buckets.last?.id, "23")
        XCTAssertEqual(buckets[9].models, ["claude-a": 5, "claude-b": 3])
        XCTAssertEqual(buckets[9].label, "9时")
        XCTAssertEqual(buckets[23].total, 4)
        XCTAssertEqual(buckets[0].total, 0)
    }

    func testUsageStoreMigratesExistingDatabaseAndMaintainsTimestamps() throws {
        let path = NSTemporaryDirectory() + "elink-usage-migration-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var legacyDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &legacyDB), SQLITE_OK)
        let legacySchema = """
        CREATE TABLE daily_model_usage (
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            PRIMARY KEY (day, provider, model)
        );
        INSERT INTO daily_model_usage VALUES ('2026-07-14', 'claude', 'claude-a', 10);
        """
        XCTAssertEqual(sqlite3_exec(legacyDB, legacySchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacyDB)

        let store = UsageStore(path: path)
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "claude-a", tokens: 10),
        ])

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        var columnsStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(daily_model_usage)", -1,
                                         &columnsStatement, nil), SQLITE_OK)
        var columns = Set<String>()
        while sqlite3_step(columnsStatement) == SQLITE_ROW,
              let name = sqlite3_column_text(columnsStatement, 1) {
            columns.insert(String(cString: name))
        }
        sqlite3_finalize(columnsStatement)
        XCTAssertTrue(columns.isSuperset(of: ["created_at", "updated_at"]))

        let oldTimestamp = "2000-01-01 00:00:00"
        let setOldTimestamps = """
        UPDATE daily_model_usage
        SET created_at = '\(oldTimestamp)', updated_at = '\(oldTimestamp)'
        """
        XCTAssertEqual(sqlite3_exec(db, setOldTimestamps, nil, nil, nil), SQLITE_OK)

        store.record(day: "2026-07-14", provider: "claude", models: ["claude-a": 25],
                     expectedBucketTimeZone: nil)

        var rowStatement: OpaquePointer?
        let rowSQL = "SELECT tokens, created_at, updated_at FROM daily_model_usage"
        XCTAssertEqual(sqlite3_prepare_v2(db, rowSQL, -1, &rowStatement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(rowStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(rowStatement, 0), 25)
        let createdAt = try XCTUnwrap(sqlite3_column_text(rowStatement, 1))
        let updatedAt = try XCTUnwrap(sqlite3_column_text(rowStatement, 2))
        XCTAssertEqual(String(cString: createdAt), oldTimestamp)
        XCTAssertNotEqual(String(cString: updatedAt), oldTimestamp)
        sqlite3_finalize(rowStatement)
    }

    func testUsageBucketMigrationCommitsRowsSnapshotsAndMarkerTogether() {
        let path = NSTemporaryDirectory() + "elink-bucket-migration-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: false)
        store.record(day: "2026-07-14", provider: "claude", models: ["sonnet": 150],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "UTC",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 150]], codex: [:]
            )
        ), .applied)

        let result = store.applyBucketMigration(
            expectedSource: "UTC",
            target: "Asia/Singapore",
            oldExplained: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 100]], codex: [:]
            ),
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-15": ["sonnet": 30]], codex: [:]
            )
        )

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(store.usageBucketTimeZone(), "Asia/Singapore")
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "sonnet", tokens: 50),
            DailyModelUsage(day: "2026-07-15", provider: "claude", model: "sonnet", tokens: 30),
        ])
        XCTAssertEqual(store.clusterManifest().map(\.revision).max(), 2)
    }

    func testRecordRejectsCapturedDayFromSupersededBucketTimeZone() {
        let path = NSTemporaryDirectory() + "elink-bucket-record-cas-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "UTC",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(claude: [:], codex: [:])
        ), .applied)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: "UTC",
            target: "Asia/Singapore",
            oldExplained: UsageHistoryTotals(claude: [:], codex: [:]),
            targetTotals: UsageHistoryTotals(claude: [:], codex: [:])
        ), .applied)

        store.record(day: "2026-07-14", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: "UTC")
        XCTAssertTrue(store.usage(provider: "claude", since: "2026-01-01").isEmpty)

        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: "Asia/Singapore")
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-15", provider: "claude", model: "sonnet", tokens: 100),
        ])
    }

    func testUsageBucketMigrationCommitFailureRollsBackRowsSnapshotsAndMarker() {
        let path = NSTemporaryDirectory() + "elink-bucket-rollback-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: false)
        store.record(day: "2026-07-14", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "UTC",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 100]], codex: [:]
            )
        ), .applied)
        let revision = store.clusterManifest().first?.revision

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &blocker), SQLITE_OK)
        defer {
            sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)
            sqlite3_close(blocker)
        }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(blocker, "SELECT COUNT(*) FROM daily_model_usage", -1,
                                         &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        defer { sqlite3_finalize(statement) }

        let result = store.applyBucketMigration(
            expectedSource: "UTC",
            target: "Asia/Singapore",
            oldExplained: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 100]], codex: [:]
            ),
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-15": ["sonnet": 100]], codex: [:]
            )
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(store.usageBucketTimeZone(), "UTC")
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "sonnet", tokens: 100),
        ])
        XCTAssertEqual(store.clusterManifest().first?.revision, revision)
    }

    func testLegacyBucketInitializationIsExplicitlyMarkedUnknown() {
        let path = NSTemporaryDirectory() + "elink-bucket-legacy-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.record(day: "2026-07-14", provider: "claude", models: ["sonnet": 110],
                     expectedBucketTimeZone: nil)

        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "Asia/Singapore",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-15": ["sonnet": 10]], codex: [:]
            )
        ), .applied)

        XCTAssertEqual(store.usageBucketTimeZone(), "Asia/Singapore")
        XCTAssertTrue(store.usageBucketHasLegacyUnknownData())
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "sonnet", tokens: 100),
            DailyModelUsage(day: "2026-07-15", provider: "claude", model: "sonnet", tokens: 10),
        ])
    }

    func testBackfillMergeDoesNotEraseDeletedLogResidueOnSameDay() {
        let path = NSTemporaryDirectory() + "elink-backfill-residue-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.record(day: "2026-07-14", provider: "claude", models: ["sonnet": 110],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.applyBucketMigration(
            expectedSource: nil,
            target: "UTC",
            oldExplained: nil,
            targetTotals: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 10]], codex: [:]
            )
        ), .applied)

        XCTAssertTrue(store.mergeBackfillTotals(
            expectedTimeZone: "UTC",
            totals: UsageHistoryTotals(
                claude: ["2026-07-14": ["sonnet": 10]], codex: [:]
            )
        ))

        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "sonnet", tokens: 110),
        ])
    }

    func testRemoteSnapshotCommitFailureIsNotReportedAsAccepted() {
        let path = NSTemporaryDirectory() + "elink-remote-rollback-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &blocker), SQLITE_OK)
        defer {
            sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)
            sqlite3_close(blocker)
        }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(blocker, "SELECT COUNT(*) FROM cluster_usage_snapshots", -1,
                                         &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        defer { sqlite3_finalize(statement) }

        let accepted = store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(
                originNodeID: "node-b", day: "2026-07-15", provider: "claude"
            ),
            revision: 1,
            observedAt: Date(),
            models: ["opus": 200]
        )], ifEpoch: store.clusterDataEpoch())

        XCTAssertNil(accepted)
        XCTAssertTrue(store.clusterManifest().isEmpty)
    }

    func testRemoteSnapshotBatchRollsBackEarlierRowsWhenLaterWriteFails() {
        let path = NSTemporaryDirectory() + "elink-remote-batch-rollback-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let trigger = """
        CREATE TRIGGER reject_node_c
        BEFORE INSERT ON cluster_usage_snapshots
        WHEN NEW.origin_node_id = 'node-c'
        BEGIN SELECT RAISE(ABORT, 'forced snapshot failure'); END;
        """
        XCTAssertEqual(sqlite3_exec(db, trigger, nil, nil, nil), SQLITE_OK)

        let accepted = store.mergeClusterSnapshots([
            ClusterUsageSnapshot(
                key: ClusterSnapshotKey(
                    originNodeID: "node-b", day: "2026-07-15", provider: "claude"
                ),
                revision: 1,
                observedAt: Date(),
                models: ["sonnet": 100]
            ),
            ClusterUsageSnapshot(
                key: ClusterSnapshotKey(
                    originNodeID: "node-c", day: "2026-07-15", provider: "claude"
                ),
                revision: 1,
                observedAt: Date(),
                models: ["opus": 200]
            ),
        ], ifEpoch: store.clusterDataEpoch())

        XCTAssertNil(accepted)
        XCTAssertTrue(store.clusterManifest().isEmpty)
    }

    func testUsageStoreRestoresUnexpiredProviderWindowsAfterRestart() throws {
        let path = NSTemporaryDirectory() + "elink-provider-cache-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            primary: UsageWindow(percent: 31, resetAt: now.addingTimeInterval(60 * 60)),
            weekly: UsageWindow(percent: 62, resetAt: now.addingTimeInterval(6 * 24 * 60 * 60)),
            fetchedAt: now.addingTimeInterval(-90)
        ))

        let restartedFetcher = UsageFetcher(cacheStore: store)
        XCTAssertEqual(restartedFetcher.claude.primary.percent, 31)
        XCTAssertEqual(restartedFetcher.claude.weekly.percent, 62)
        XCTAssertTrue(restartedFetcher.claude.isCached)
        XCTAssertTrue((58...60).contains(
            try XCTUnwrap(restartedFetcher.claude.primary.resetMinutes)))
    }

    func testWindowlessResponseDoesNotWipePersistedProviderCache() {
        let path = NSTemporaryDirectory() + "elink-provider-windowless-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            primary: UsageWindow(percent: 31, resetAt: now.addingTimeInterval(60 * 60)),
            weekly: UsageWindow(percent: 62, resetAt: now.addingTimeInterval(6 * 24 * 60 * 60)),
            fetchedAt: now
        ))
        // HTTP 200 但缺少窗口字段的响应不能删掉上一次有效缓存
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            fetchedAt: now.addingTimeInterval(10)
        ))

        let restored = store.cachedUsage(provider: "claude", now: now.addingTimeInterval(20))
        XCTAssertEqual(restored?.primary.percent, 31)
        XCTAssertEqual(restored?.weekly.percent, 62)
    }

    func testUsageStoreDropsOnlyExpiredWindowAndReplacesOldRows() {
        let path = NSTemporaryDirectory() + "elink-provider-expiry-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "codex", usage: ProviderUsage(
            primary: UsageWindow(percent: 80, resetAt: now.addingTimeInterval(60)),
            weekly: UsageWindow(percent: 70, resetAt: now.addingTimeInterval(60)),
            fetchedAt: now
        ))
        store.cacheUsage(provider: "codex", usage: ProviderUsage(
            weekly: UsageWindow(percent: 0, resetAt: now.addingTimeInterval(7 * 24 * 60 * 60)),
            fetchedAt: now.addingTimeInterval(10)
        ))

        let restored = store.cachedUsage(provider: "codex", now: now.addingTimeInterval(20))
        XCTAssertNil(restored?.primary.percent)
        XCTAssertEqual(restored?.weekly.percent, 0)
    }

    func testUsageStoreRejectsExpiredCachedWindow() {
        let path = NSTemporaryDirectory() + "elink-provider-expired-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            primary: UsageWindow(percent: 48, resetAt: now.addingTimeInterval(-1)),
            fetchedAt: now.addingTimeInterval(-60)
        ))

        XCTAssertNil(store.cachedUsage(provider: "claude", now: now))
    }

    func testUsageStoreRejectsOldWindowWithoutResetTime() {
        let path = NSTemporaryDirectory() + "elink-provider-no-reset-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            weekly: UsageWindow(percent: 51),
            fetchedAt: now.addingTimeInterval(-7 * 60 * 60)
        ))

        XCTAssertNil(store.cachedUsage(provider: "claude", now: now))
    }

    func testOlderFallbackCannotOverwriteNewerProviderCache() {
        let path = NSTemporaryDirectory() + "elink-provider-newest-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let now = Date()
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            weekly: UsageWindow(percent: 80, resetAt: now.addingTimeInterval(60 * 60)),
            fetchedAt: now
        ))
        store.cacheUsage(provider: "claude", usage: ProviderUsage(
            weekly: UsageWindow(percent: 20, resetAt: now.addingTimeInterval(60 * 60)),
            fetchedAt: now.addingTimeInterval(-60)
        ))

        XCTAssertEqual(store.cachedUsage(provider: "claude", now: now)?.weekly.percent, 80)
    }

    func testStatsBucketsCoverRangeAndAggregateYearByMonth() {
        let now = Date()
        let calendar = Calendar.current
        let today = StatusService.dayKey(now)
        let yesterday = StatusService.dayKey(calendar.date(byAdding: .day, value: -1, to: now)!)
        let rows = [
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 30),
            DailyModelUsage(day: today, provider: "claude", model: "claude-b", tokens: 10),
            DailyModelUsage(day: yesterday, provider: "claude", model: "claude-a", tokens: 5),
        ]

        let week = UsageStats.buckets(rows: rows, range: .week, now: now)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.id, today)
        XCTAssertEqual(week.last?.models, ["claude-a": 30, "claude-b": 10])
        XCTAssertEqual(week[5].models, ["claude-a": 5])
        XCTAssertEqual(UsageStats.modelOrder(week), ["claude-a", "claude-b"])

        let year = UsageStats.buckets(rows: rows, range: .year, now: now)
        XCTAssertEqual(year.count, 12)
        XCTAssertEqual(year.last?.id, String(today.prefix(7)))
        // 昨天可能落在上个月，因此只校验全年总量
        XCTAssertEqual(year.reduce(0) { $0 + $1.total }, 45)

        XCTAssertEqual(UsageStatsView.percentText(30, of: 40), "75%")
        XCTAssertEqual(UsageStatsView.percentText(0, of: 0), "0%")
    }

    func testStatsBucketLabelsFollowAggregationTimeZone() {
        StatusService.setAggregationTimeZone("Pacific/Kiritimati")
        defer { StatusService.setAggregationTimeZone(nil) }
        // 2023-11-14 12:00 UTC，在 UTC+14 已是 11-15，UTC+11 及以西时区仍是 11-14
        let reference = Date(timeIntervalSince1970: 1_699_963_200)

        let week = UsageStats.buckets(rows: [], range: .week, now: reference)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.id, StatusService.dayKey(reference))
        for bucket in week {
            let parts = bucket.id.split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(bucket.label, "\(parts[1])/\(parts[2])", "label 与数据键日期不一致: \(bucket.id)")
        }

        let year = UsageStats.buckets(rows: [], range: .year, now: reference)
        XCTAssertEqual(year.count, 12)
        XCTAssertEqual(year.last?.id, String(StatusService.dayKey(reference).prefix(7)))
        for bucket in year {
            let month = try? XCTUnwrap(Int(bucket.id.suffix(2)))
            XCTAssertEqual(bucket.label, "\(month ?? 0)月", "月份标签与数据键不一致: \(bucket.id)")
        }
    }

    func testDeviceTotalsAggregateAndSortByTokensDesc() {
        let now = Date()
        let calendar = Calendar.current
        let today = StatusService.dayKey(now)
        let yesterday = StatusService.dayKey(calendar.date(byAdding: .day, value: -1, to: now)!)
        let rows = [
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 30, nodeID: "node-a"),
            DailyModelUsage(day: yesterday, provider: "claude", model: "claude-b", tokens: 10, nodeID: "node-a"),
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 50, nodeID: "node-b"),
            DailyModelUsage(day: yesterday, provider: "claude", model: "claude-a", tokens: 20, nodeID: "node-b"),
        ]

        let devices = UsageStats.deviceTotals(rows: rows, range: .week, now: now)
        XCTAssertEqual(devices.map(\.nodeID), ["node-b", "node-a"])
        XCTAssertEqual(devices[0].models, ["claude-a": 70])
        XCTAssertEqual(devices[0].total, 70)
        XCTAssertEqual(devices[1].models, ["claude-a": 30, "claude-b": 10])
        XCTAssertEqual(UsageStatsView.percentText(70, of: 110), "64%")
    }

    func testDeviceTotalsRespectRangeWindow() {
        let now = Date()
        let calendar = Calendar.current
        let today = StatusService.dayKey(now)
        let old = StatusService.dayKey(calendar.date(byAdding: .day, value: -40, to: now)!)
        let rows = [
            DailyModelUsage(day: old, provider: "claude", model: "claude-a", tokens: 100, nodeID: "node-a"),
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 30, nodeID: "node-b"),
        ]

        // 设备总和必须与图表总量一致（40 天前的行在周/月被排除、年包含）
        for range in StatsRange.allCases {
            let devices = UsageStats.deviceTotals(rows: rows, range: range, now: now)
            let chartTotal = UsageStats.buckets(rows: rows, range: range, now: now)
                .reduce(0) { $0 + $1.total }
            XCTAssertEqual(devices.reduce(0) { $0 + $1.total }, chartTotal, "range \(range)")
        }
        XCTAssertEqual(UsageStats.deviceTotals(rows: rows, range: .week, now: now).map(\.nodeID),
                       ["node-b"])
        XCTAssertEqual(UsageStats.deviceTotals(rows: rows, range: .year, now: now).map(\.nodeID),
                       ["node-a", "node-b"])
    }

    func testDeviceTotalsFilteredToHoveredBucketMatchBucketTotal() {
        let now = Date()
        let calendar = Calendar.current
        let today = StatusService.dayKey(now)
        let yesterday = StatusService.dayKey(calendar.date(byAdding: .day, value: -1, to: now)!)
        let rows = [
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 30, nodeID: "node-a"),
            DailyModelUsage(day: yesterday, provider: "claude", model: "claude-a", tokens: 50, nodeID: "node-a"),
            DailyModelUsage(day: today, provider: "claude", model: "claude-b", tokens: 20, nodeID: "node-b"),
        ]

        // 悬停某天时，设备总和必须等于该天柱子的总量（与 detail 口径一致）
        let devices = UsageStats.deviceTotals(rows: rows, range: .week, now: now, bucketID: today)
        let bucket = UsageStats.buckets(rows: rows, range: .week, now: now).first { $0.id == today }
        XCTAssertEqual(devices.reduce(0) { $0 + $1.total }, bucket?.total)
        XCTAssertEqual(devices.map(\.nodeID), ["node-a", "node-b"])
        XCTAssertEqual(devices[0].models, ["claude-a": 30])

        // 年视图悬停某月：按月前缀过滤
        let monthKey = String(today.prefix(7))
        let yearDevices = UsageStats.deviceTotals(rows: rows, range: .year, now: now, bucketID: monthKey)
        let yearBucket = UsageStats.buckets(rows: rows, range: .year, now: now).first { $0.id == monthKey }
        XCTAssertEqual(yearDevices.reduce(0) { $0 + $1.total }, yearBucket?.total)
    }

    func testDeviceTotalsGroupNilNodeSeparatelyAndStableTieBreak() {
        let now = Date()
        let today = StatusService.dayKey(now)
        let rows = [
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 10),
            DailyModelUsage(day: today, provider: "claude", model: "claude-a", tokens: 20, nodeID: "node-b"),
            DailyModelUsage(day: today, provider: "claude", model: "claude-b", tokens: 20, nodeID: "node-a"),
        ]

        let devices = UsageStats.deviceTotals(rows: rows, range: .week, now: now)
        XCTAssertEqual(devices.map(\.nodeID), ["node-a", "node-b", nil])
        XCTAssertEqual(devices.last?.models, ["claude-a": 10])
    }

    func testRejectsOldDeviceShape() {
        XCTAssertThrowsError(try DeviceInfo(json: ["device_type": "esp8266"]))
    }

    func testParsesDetailedDeviceState() throws {
        let info = try DeviceInfo(json: [
            "device_type": "elink-agent",
            "version": "0.1.12",
            "bridge_url": "http://192.168.1.2:8765",
            "mode": "codex",
            "stale": false,
            "last_fetch_age_s": 3,
            "last_refresh_age_s": 42,
            "last_refresh_kind": "partial",
        ])

        XCTAssertEqual(info.lastFetchAge, 3)
        XCTAssertEqual(info.lastRefreshAge, 42)
        XCTAssertEqual(info.version, "0.1.12")
        XCTAssertEqual(PreviewPopoverController.segment(for: info.mode), 2)
        let summary = PreviewPopoverController.deviceSummary(info)
        XCTAssertTrue(summary.contains("42秒前送屏"))
        XCTAssertTrue(summary.contains("v0.1.12"))
    }

    func testDeviceSummaryOmitsVersionWhenAgentDoesNotReportOne() throws {
        let info = try DeviceInfo(json: ["device_type": "elink-agent", "mode": "dashboard"])
        XCTAssertNil(info.version)
        XCTAssertFalse(PreviewPopoverController.deviceSummary(info).contains(" v"))
    }

    func testNormalizesDeviceHost() {
        XCTAssertEqual(DeviceClient.normalizedHost(" https://192.168.1.50:8766/ "),
                       "192.168.1.50:8766")
    }

    func testDeviceConnectionDefaultsToEnabledAndPersistsToggle() throws {
        let suiteName = "elink-device-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(DeviceClient.connectionEnabled(in: defaults))
        DeviceClient.setConnectionEnabled(false, in: defaults)
        XCTAssertFalse(DeviceClient.connectionEnabled(in: defaults))
        DeviceClient.setConnectionEnabled(true, in: defaults)
        XCTAssertTrue(DeviceClient.connectionEnabled(in: defaults))
    }

    func testUsageMenuIncludesResetTimes() {
        let usage = ProviderUsage(
            primary: UsageWindow(percent: 4, resetMinutes: 127),
            weekly: UsageWindow(percent: 45, resetMinutes: 3 * 24 * 60 + 15 * 60)
        )

        let line = MenuBarController.usageLine("Claude", usage)
        XCTAssertTrue(line.contains("5h 4% · 2h 7m"))
        XCTAssertTrue(line.contains("周 45% · 3d 15h"))
    }

    func testParsesClaudeStatuslineCache() throws {
        let now = Date().timeIntervalSince1970
        let json: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": 4, "resets_at": now + 90 * 60],
                "seven_day": ["used_percentage": 45, "resets_at": now + 3 * 24 * 60 * 60],
            ],
        ]

        let usage = try XCTUnwrap(UsageFetcher.claudeStatuslineUsage(json, fetchedAt: Date()))
        XCTAssertEqual(usage.primary.percent, 4)
        XCTAssertEqual(try XCTUnwrap(usage.primary.resetMinutes), 90, accuracy: 1)
        XCTAssertEqual(usage.weekly.percent, 45)
        XCTAssertEqual(try XCTUnwrap(usage.weekly.resetMinutes), 3 * 24 * 60, accuracy: 1)
    }

    func testExpiredWindowShowsDashInsteadOfZeroMinutes() throws {
        let json: [String: Any] = [
            "rate_limits": [
                "five_hour": ["used_percentage": 2, "resets_at": Date().timeIntervalSince1970 - 60],
                "seven_day": ["used_percentage": 45, "resets_at": Date().timeIntervalSince1970 + 3 * 24 * 60 * 60],
            ],
        ]

        let usage = try XCTUnwrap(UsageFetcher.claudeStatuslineUsage(json, fetchedAt: Date()))
        XCTAssertNil(usage.primary.percent)
        XCTAssertNil(usage.primary.resetMinutes)
        XCTAssertTrue(MenuBarController.usageLine("Claude", usage).contains("5h —"))
    }

    func testClassifiesSevenDayCodexPrimaryWindowAsWeekly() {
        let limits: [String: Any] = [
            "primary_window": [
                "used_percent": 18,
                "limit_window_seconds": 7 * 24 * 60 * 60,
                "reset_at": Date().timeIntervalSince1970 + 6 * 24 * 60 * 60,
            ],
            "secondary_window": NSNull(),
        ]

        let windows = UsageFetcher.codexWindows(limits)
        XCTAssertNil(windows.primary.percent)
        XCTAssertEqual(windows.weekly.percent, 18)
    }

    func testClassifiesCodexWindowsByDuration() {
        let reset = Date().timeIntervalSince1970 + 60 * 60
        let limits: [String: Any] = [
            "primary_window": [
                "used_percent": 13,
                "limit_window_seconds": 5 * 60 * 60,
                "reset_at": reset,
            ],
            "secondary_window": [
                "used_percent": 42,
                "limit_window_seconds": 7 * 24 * 60 * 60,
                "reset_at": reset,
            ],
        ]

        let windows = UsageFetcher.codexWindows(limits)
        XCTAssertEqual(windows.primary.percent, 13)
        XCTAssertEqual(windows.weekly.percent, 42)
    }

    func testClassifiesCodexLogWindowByDuration() {
        let limits: [String: Any] = [
            "primary": [
                "used_percent": 18,
                "window_minutes": 7 * 24 * 60,
                "resets_at": Date().timeIntervalSince1970 + 60 * 60,
            ],
        ]

        let windows = UsageFetcher.codexLogWindows(limits)
        XCTAssertNil(windows.primary.percent)
        XCTAssertEqual(windows.weekly.percent, 18)
    }

    func testClaudeTokenFromShellOutputExtractsToken() {
        let noisy = "p10k banner\nELINK_TOKEN<sk-ant-oat01-abc123>\n"
        XCTAssertEqual(UsageFetcher.claudeTokenFromShellOutput(noisy), "sk-ant-oat01-abc123")
        XCTAssertNil(UsageFetcher.claudeTokenFromShellOutput("ELINK_TOKEN<>"))
        XCTAssertNil(UsageFetcher.claudeTokenFromShellOutput("no marker here"))
    }

    func testUsageLevelThresholdsFollowRemainingPercent() {
        XCTAssertEqual(UsageLevel.level(usedPercent: 10), .healthy)
        XCTAssertEqual(UsageLevel.level(usedPercent: 50), .healthy)
        XCTAssertEqual(UsageLevel.level(usedPercent: 51), .warning)
        XCTAssertEqual(UsageLevel.level(usedPercent: 80), .warning)
        XCTAssertEqual(UsageLevel.level(usedPercent: 81), .critical)
        XCTAssertEqual(UsageLevel.level(usedPercent: 100), .critical)
    }

    func testStatusTitleShowsColoredPercent() {
        let title = MenuBarController.statusTitle(percent: 42)
        XCTAssertEqual(title.string, "42%")
        let color = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemGreen)
        XCTAssertEqual(MenuBarController.statusColor(percent: 51), .systemOrange)
        XCTAssertEqual(MenuBarController.statusColor(percent: 81), .systemRed)
    }

    func testMenuBarUsesLargestProviderWeeklyUsage() {
        XCTAssertEqual(MenuBarController.menuBarWeeklyPercent(claudeWeekly: 47, codexWeekly: 68), 68)
        XCTAssertEqual(MenuBarController.menuBarWeeklyPercent(claudeWeekly: 47, codexWeekly: nil), 47)
        XCTAssertNil(MenuBarController.menuBarWeeklyPercent(claudeWeekly: nil, codexWeekly: nil))
    }

    func testMenuBarUsesDedicatedLogoInDevelopmentBuild() {
        XCTAssertNotNil(AppLogo.menuBarImage)
    }

    func testFormatsTokenCounts() {
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormat.tokens(2_340_000), "2.3M")
        XCTAssertEqual(UsageFormat.tokens(1_567_600_000), "1.6B")
    }

    func testLaunchAtLoginWritesAndRemovesPlist() throws {
        let path = NSTemporaryDirectory() + "elink-test-\(UUID().uuidString)/launch.plist"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        XCTAssertFalse(LaunchAtLogin.isEnabled(at: path))
        try LaunchAtLogin.setEnabled(true, at: path)
        XCTAssertTrue(LaunchAtLogin.isEnabled(at: path))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "local.elink-ai-bridge")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertFalse((plist["ProgramArguments"] as? [String] ?? []).isEmpty)
        XCTAssertEqual(plist["StandardOutPath"] as? String, AppInfo.consoleLogURL.path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, AppInfo.consoleLogURL.path)

        try LaunchAtLogin.setEnabled(false, at: path)
        XCTAssertFalse(LaunchAtLogin.isEnabled(at: path))
    }

    func testLaunchAtLoginRefreshesStaleExecutablePath() throws {
        let path = NSTemporaryDirectory() + "elink-test-\(UUID().uuidString)/launch.plist"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let stalePlist: [String: Any] = [
            "Label": "local.elink-ai-bridge",
            "ProgramArguments": ["/Applications/Elink AI old.app/Contents/MacOS/ElinkAIBridge"],
            "RunAtLoad": true,
        ]
        let staleData = try PropertyListSerialization.data(
            fromPropertyList: stalePlist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try staleData.write(to: URL(fileURLWithPath: path))

        try LaunchAtLogin.refreshIfEnabled(at: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.first, executable)
    }

    func testApplicationLogUsesPersistentUserLibraryLocation() {
        XCTAssertTrue(AppInfo.logPath.contains("/Library/Logs/Elink AI/"))
        XCTAssertFalse(AppInfo.logPath.hasPrefix("/tmp/"))
        XCTAssertEqual(AppInfo.logURL.lastPathComponent, "elink-ai.log")
    }

    func testLogRedactsCredentials() {
        let message = #"Authorization: Bearer secret-token access_token=abc123 api-key: key456"#
        let result = Log.redacted(message)

        XCTAssertFalse(result.contains("secret-token"))
        XCTAssertFalse(result.contains("abc123"))
        XCTAssertFalse(result.contains("key456"))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    func testLogDefinesThreeLevelsAndFormatsThem() {
        XCTAssertEqual(Log.Level.allCases.map(\.rawValue), ["INFO", "WARNING", "ERROR"])

        let warning = Log.formattedLine(
            level: .warning,
            category: "device",
            message: "request timed out",
            at: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(warning.contains("[WARNING] [device] request timed out"))
        XCTAssertTrue(warning.hasSuffix("\n"))
    }

    func testUpdateCheckerComparesSemanticVersions() {
        XCTAssertTrue(UpdateChecker.isVersion("0.1.10", newerThan: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isVersion("v1.0.0", newerThan: "0.9.99"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.0-beta.2", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0-rc.1"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.1.3", newerThan: "0.1.3"))
    }

    func testUpdateCheckerSelectsStableOrPrereleaseChannel() throws {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: Data(#"""
        [
          {"tag_name":"v9.0.0","draft":true,"prerelease":false,
           "html_url":"https://example.com/draft","assets":[]},
          {"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":true,
           "html_url":"https://example.com/beta","assets":[]},
          {"tag_name":"v0.1.10","draft":false,"prerelease":false,
           "html_url":"https://example.com/stable","assets":[]},
          {"tag_name":"v0.1.9","draft":false,"prerelease":false,
           "html_url":"https://example.com/old","assets":[]}
        ]
        """#.utf8))

        XCTAssertEqual(UpdateChecker.newestRelease(
            in: releases, includesPrereleases: false)?.version, "0.1.10")
        XCTAssertEqual(UpdateChecker.newestRelease(
            in: releases, includesPrereleases: true)?.version, "0.2.0-beta.1")
    }

    func testUpdateCheckerUsesVersionedDMGAsset() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(#"""
        {
          "tag_name":"v0.1.3","draft":false,"prerelease":false,
          "html_url":"https://github.com/ChyiYaqing/elink-ai/releases/tag/v0.1.3",
          "assets":[
            {"name":"another.dmg","browser_download_url":"https://example.com/another.dmg"},
            {"name":"elink-ai-v0.1.3.dmg","browser_download_url":"https://example.com/elink-ai-v0.1.3.dmg"}
          ]
        }
        """#.utf8))

        XCTAssertEqual(release.dmgURL?.absoluteString,
                       "https://example.com/elink-ai-v0.1.3.dmg")
    }

    func testKeepsLastGoodWeeklyOnlyUsageAfterError() {
        let old = ProviderUsage(weekly: UsageWindow(percent: 18, resetMinutes: 60))
        let failed = ProviderUsage(error: "temporary error")

        let result = UsageFetcher.keepLastGood(old: old, new: failed)
        XCTAssertEqual(result.weekly.percent, 18)
        XCTAssertEqual(result.error, "temporary error")
        XCTAssertTrue(result.isCached)
    }

    func testDoesNotKeepExpiredUsageAfterError() {
        let old = ProviderUsage(
            primary: UsageWindow(
                percent: 70,
                resetMinutes: nil,
                resetAt: Date(timeIntervalSinceNow: -60)
            ),
            weekly: UsageWindow(
                percent: 52,
                resetMinutes: 60,
                resetAt: Date(timeIntervalSinceNow: 60 * 60)
            )
        )
        let failed = ProviderUsage(error: "temporary error")

        let result = UsageFetcher.keepLastGood(old: old, new: failed)

        XCTAssertNil(result.primary.percent)
        XCTAssertEqual(result.weekly.percent, 52)
        XCTAssertEqual(result.error, "temporary error")
    }

    func testStaleCachedFallbackDoesNotOverrideFresherStoredUsage() {
        let now = Date()
        let old = ProviderUsage(
            primary: UsageWindow(percent: 40, resetMinutes: 120,
                                 resetAt: now.addingTimeInterval(7200)),
            fetchedAt: now.addingTimeInterval(-300)
        )
        let staleCached = ProviderUsage(
            primary: UsageWindow(percent: 12, resetMinutes: 60,
                                 resetAt: now.addingTimeInterval(3600)),
            error: "Claude 用量请求失败",
            fetchedAt: now.addingTimeInterval(-3 * 3600),
            isCached: true
        )

        let result = UsageFetcher.keepLastGood(old: old, new: staleCached)

        XCTAssertEqual(result.primary.percent, 40)
        XCTAssertEqual(result.error, "Claude 用量请求失败")
        XCTAssertTrue(result.isCached)
    }

    func testFresherCachedFallbackReplacesOlderStoredUsage() {
        let now = Date()
        let old = ProviderUsage(
            primary: UsageWindow(percent: 40, resetMinutes: 120,
                                 resetAt: now.addingTimeInterval(7200)),
            fetchedAt: now.addingTimeInterval(-2 * 3600)
        )
        let cached = ProviderUsage(
            primary: UsageWindow(percent: 55, resetMinutes: 60,
                                 resetAt: now.addingTimeInterval(3600)),
            fetchedAt: now.addingTimeInterval(-600),
            isCached: true
        )

        let result = UsageFetcher.keepLastGood(old: old, new: cached)

        XCTAssertEqual(result.primary.percent, 55)
    }

    func testUsageLogDescriptionIncludesValuesCacheAndError() {
        let usage = ProviderUsage(
            primary: UsageWindow(percent: 102),
            weekly: UsageWindow(percent: 10),
            error: "Claude 用量 HTTP 429",
            isCached: true
        )

        XCTAssertEqual(
            UsageFetcher.describe(usage),
            "primary=102% weekly=10% cached error=Claude 用量 HTTP 429"
        )
    }

    func testRateLimitedExhaustedUsageShowsResetInsteadOfFailure() throws {
        let now = Date(timeIntervalSince1970: 0)
        let resetAt = Date(timeIntervalSince1970: 8 * 60 * 60 + 20 * 60)
        let status = AgentStatus(
            primary: UsageWindow(percent: 102, resetAt: resetAt),
            error: "Claude 用量 HTTP 429",
            usageFetchedAt: now,
            usageCached: true
        )

        let notice = try XCTUnwrap(UsagePresentation.notice(
            status,
            now: now,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        ))
        XCTAssertEqual(notice.kind, .limit)
        XCTAssertEqual(notice.text, "已达到用量上限 · 08:20 重置")
        XCTAssertFalse(notice.text.contains("更新失败"))
    }

    func testFreshCachedRateLimitDoesNotShowWarning() {
        let now = Date(timeIntervalSince1970: 10_000)
        let status = AgentStatus(
            primary: UsageWindow(percent: 72),
            error: "Claude 用量 HTTP 429",
            usageFetchedAt: now.addingTimeInterval(-120),
            usageCached: true
        )

        XCTAssertNil(UsagePresentation.notice(status, now: now))
    }

    func testStaleCachedRateLimitShowsSoftNotice() {
        let now = Date(timeIntervalSince1970: 10_000)
        let status = AgentStatus(
            primary: UsageWindow(percent: 72),
            error: "Claude 用量 HTTP 429",
            usageFetchedAt: now.addingTimeInterval(-601),
            usageCached: true
        )

        XCTAssertEqual(
            UsagePresentation.notice(status, now: now),
            UsagePresentation.Notice(
                kind: .cachedRateLimit,
                text: "用量更新受限 · 显示缓存"
            )
        )
    }

    func testNonRateLimitErrorStillShowsFailure() {
        let status = AgentStatus(
            primary: UsageWindow(percent: 50),
            error: "Claude 用量响应解析失败"
        )

        XCTAssertEqual(
            UsagePresentation.notice(status),
            UsagePresentation.Notice(
                kind: .failure,
                text: "更新失败 · Claude 用量响应解析失败"
            )
        )
    }

    func testMissingUsageDoesNotRepeatErrorAsNotice() {
        let status = AgentStatus(error: "Claude 用量请求失败")

        XCTAssertEqual(UsagePresentation.missingPrimaryText(status), "Claude 用量请求失败")
        XCTAssertNil(UsagePresentation.notice(status))
    }

    func testWeeklyOnlyUsageDoesNotClaimAllUsageIsMissing() {
        let status = AgentStatus(
            weekly: UsageWindow(percent: 0),
            error: "temporary error"
        )
        XCTAssertEqual(UsagePresentation.missingPrimaryText(status),
                       "当前无活跃的 5 小时窗口")
    }

    func testProviderFreshnessIdentifiesCachedData() {
        let now = Date(timeIntervalSince1970: 10_000)
        let status = AgentStatus(
            usageFetchedAt: now.addingTimeInterval(-120),
            usageCached: true
        )
        XCTAssertEqual(UsagePresentation.freshnessText(status, now: now), "缓存 · 2分钟前")
    }
}
