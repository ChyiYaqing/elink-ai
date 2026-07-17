import XCTest
import SQLite3
@testable import ElinkAIBridge

final class ModelsTests: XCTestCase {
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

    func testUsageStoreUpsertsAndQueriesByProviderAndDay() {
        let path = NSTemporaryDirectory() + "elink-usage-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)

        store.record(day: "2026-07-13", provider: "claude", models: ["claude-a": 100, "claude-b": 50])
        store.record(day: "2026-07-14", provider: "claude", models: ["claude-a": 10, "empty": 0])
        store.record(day: "2026-07-14", provider: "codex", models: ["gpt-a": 7])
        store.record(day: "2026-07-14", provider: "claude", models: ["claude-a": 25])

        XCTAssertEqual(store.usage(provider: "claude", since: "2026-07-14"), [
            DailyModelUsage(day: "2026-07-14", provider: "claude", model: "claude-a", tokens: 25),
        ])
        XCTAssertEqual(store.usage(provider: "claude", since: "2026-01-01").count, 3)
        XCTAssertEqual(store.usage(provider: "codex", since: "2026-01-01"), [
            DailyModelUsage(day: "2026-07-14", provider: "codex", model: "gpt-a", tokens: 7),
        ])
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

        store.record(day: "2026-07-14", provider: "claude", models: ["claude-a": 25])

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
