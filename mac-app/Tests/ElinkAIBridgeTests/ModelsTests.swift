import XCTest
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
        let models = try XCTUnwrap(claude["model_usage_today"] as? [[String: Any]])
        XCTAssertEqual(models.first?["model"] as? String, "claude-sonnet")
        XCTAssertEqual(models.first?["tokens"] as? Int, 1200)
    }

    func testClaudeUsageIsDeduplicatedAndGroupedByModel() {
        let first = #"{"timestamp":"1970-01-01T00:20:00.000Z","uuid":"one","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:01.000Z","uuid":"two","message":{"id":"msg-1","model":"claude-a","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        let second = #"{"timestamp":"1970-01-01T00:20:02.000Z","uuid":"three","message":{"id":"msg-2","model":"claude-b","usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

        let usage = StatusService.claudeModelUsage(
            lines: [first, duplicate, second],
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 5_000)
        )

        XCTAssertEqual(usage, [
            ModelUsage(model: "claude-a", tokens: 20),
            ModelUsage(model: "claude-b", tokens: 7),
        ])
    }

    func testCodexUsageFollowsModelChangesAndSkipsDuplicateCounts() {
        let modelA = #"{"timestamp":"1970-01-01T00:20:00.000Z","type":"turn_context","payload":{"model":"gpt-a"}}"#
        let countA = #"{"timestamp":"1970-01-01T00:20:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"total_tokens":10}}}}"#
        let duplicate = #"{"timestamp":"1970-01-01T00:20:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"total_tokens":10}}}}"#
        let modelB = #"{"timestamp":"1970-01-01T00:20:03.000Z","type":"turn_context","payload":{"model":"gpt-b"}}"#
        let countB = #"{"timestamp":"1970-01-01T00:20:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":30},"last_token_usage":{"total_tokens":20}}}}"#

        let usage = StatusService.codexModelUsage(
            sessions: [[modelA, countA, duplicate, modelB, countB]],
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 5_000)
        )

        XCTAssertEqual(usage, [
            ModelUsage(model: "gpt-b", tokens: 20),
            ModelUsage(model: "gpt-a", tokens: 10),
        ])
    }

    func testRejectsOldDeviceShape() {
        XCTAssertThrowsError(try DeviceInfo(json: ["device_type": "esp8266"]))
    }

    func testParsesDetailedDeviceState() throws {
        let info = try DeviceInfo(json: [
            "device_type": "elink-agent",
            "bridge_url": "http://192.168.1.2:8765",
            "mode": "codex",
            "stale": false,
            "last_fetch_age_s": 3,
            "last_refresh_age_s": 42,
            "last_refresh_kind": "partial",
        ])

        XCTAssertEqual(info.lastFetchAge, 3)
        XCTAssertEqual(info.lastRefreshAge, 42)
        XCTAssertEqual(PreviewPopoverController.segment(for: info.mode), 2)
        XCTAssertTrue(PreviewPopoverController.deviceSummary(info).contains("42秒前送屏"))
    }

    func testNormalizesDeviceHost() {
        XCTAssertEqual(DeviceClient.normalizedHost(" https://192.168.1.50:8766/ "),
                       "192.168.1.50:8766")
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

    func testFormatsTokenCounts() {
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormat.tokens(2_340_000), "2.3M")
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

        try LaunchAtLogin.setEnabled(false, at: path)
        XCTAssertFalse(LaunchAtLogin.isEnabled(at: path))
    }

    func testKeepsLastGoodWeeklyOnlyUsageAfterError() {
        let old = ProviderUsage(weekly: UsageWindow(percent: 18, resetMinutes: 60))
        let failed = ProviderUsage(error: "temporary error")

        let result = UsageFetcher.keepLastGood(old: old, new: failed)
        XCTAssertEqual(result.weekly.percent, 18)
        XCTAssertEqual(result.error, "temporary error")
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
}
