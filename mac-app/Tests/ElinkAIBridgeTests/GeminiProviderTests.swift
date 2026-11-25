import XCTest
@testable import ElinkAIBridge

final class GeminiProviderTests: XCTestCase {
    func testGeminiFallbackOnlyWhenAPIHasNoWindowAndKeepsAPIError() {
        let now = Date()
        func window(_ percent: Double) -> UsageWindow {
            UsageWindow(percent: percent, resetMinutes: 60, resetAt: now.addingTimeInterval(3600))
        }
        let stale = ProviderUsage(primary: window(10), weekly: window(40),
                                  fetchedAt: now.addingTimeInterval(-1800))

        // API 只给了短窗口：不拿旧缓存的周窗口冒充本轮数据
        let partial = UsageFetcher.mergeGeminiFallback(
            live: ProviderUsage(primary: window(20), fetchedAt: now), stale: stale)
        XCTAssertEqual(partial.primary.percent, 20)
        XCTAssertNil(partial.weekly.percent)
        XCTAssertFalse(partial.isCached)

        // API 429：旧缓存兜底，标为缓存，错误保留给退避识别
        let fallback = UsageFetcher.mergeGeminiFallback(
            live: ProviderUsage(error: "Gemini usage HTTP 429"), stale: stale)
        XCTAssertTrue(fallback.isCached)
        XCTAssertEqual(fallback.weekly.percent, 40)
        XCTAssertEqual(fallback.error, "Gemini usage HTTP 429")

        // 内存里更新的 API 值不被更旧的缓存覆盖
        let newer = ProviderUsage(primary: window(30), weekly: window(50),
                                  fetchedAt: now.addingTimeInterval(-60))
        let kept = UsageFetcher.keepLastGood(old: newer, new: fallback)
        XCTAssertEqual(kept.primary.percent, 30)
        XCTAssertEqual(kept.error, "Gemini usage HTTP 429")
    }

    func testParsesGeminiFiveHourAndWeeklyQuotaBuckets() {
        let now = Date(timeIntervalSince1970: 1_783_933_200) // 2026-07-13T09:00:00Z
        let payload: [String: Any] = [
            "buckets": [
                [
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.6,
                    "resetTime": "2026-07-13T12:00:00Z",
                    "window": "5h",
                ],
                [
                    "modelId": "gemini-2.5-flash",
                    "remainingFraction": 0.85,
                    "resetTime": "2026-07-13T13:00:00Z",
                    "window": "5h",
                ],
                [
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.3,
                    "resetTime": "2026-07-18T09:00:00Z",
                    "window": "weekly",
                ],
            ]
        ]

        let usage = UsageFetcher.geminiUsage(payload, fetchedAt: now, now: now)
        XCTAssertEqual(usage.primary.percent ?? -1, 40.0, accuracy: 0.001)
        XCTAssertEqual(usage.primary.resetMinutes, 180)
        XCTAssertEqual(usage.weekly.percent ?? -1, 70.0, accuracy: 0.001)
        XCTAssertEqual(usage.weekly.resetMinutes, 5 * 24 * 60)
        XCTAssertEqual(usage.scopedLimits.count, 3)
        XCTAssertEqual(usage.scopedLimits[0].title, "Pro")
        XCTAssertEqual(usage.scopedLimits[1].title, "Flash")
    }

    func testGeminiMissingWeeklyWindowRemainsNil() {
        let now = Date(timeIntervalSince1970: 1_783_933_200)
        let payload: [String: Any] = [
            "buckets": [
                [
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.75,
                    "resetTime": "2026-07-13T14:00:00Z",
                ]
            ]
        ]

        let usage = UsageFetcher.geminiUsage(payload, fetchedAt: now, now: now)
        XCTAssertEqual(usage.primary.percent ?? -1, 25.0, accuracy: 0.001)
        XCTAssertNil(usage.weekly.percent)
        XCTAssertTrue(usage.scopedLimits.isEmpty)
    }

    func testParsesGeminiOAuthCredentials() throws {
        let now = Date(timeIntervalSince1970: 1_783_933_200)
        let data = Data("""
        {
          "access_token": "ya29.test",
          "refresh_token": "1//refresh",
          "expiry_date": 1783936800000
        }
        """.utf8)
        let creds = try UsageFetcher.geminiCredentials(fileData: data).get()
        XCTAssertEqual(creds.accessToken, "ya29.test")
        XCTAssertEqual(creds.refreshToken, "1//refresh")
        XCTAssertTrue(creds.accessTokenIsValid(at: now))
        XCTAssertFalse(creds.accessTokenIsValid(at: now.addingTimeInterval(3600)))
    }

    /// Gemini CLI `.jsonl` 是操作日志：`$set.messages` 里的消息也要计入，
    /// 同一 id 只算一次，`$rewindTo` 回退掉的消息 token 已经花出去，照样计入。
    func testGeminiJSONLOperationLogCountsEveryMessageOnce() throws {
        func msg(_ id: String, _ output: Int) -> String {
            #"{"id":"\#(id)","timestamp":"2026-11-25T02:00:00Z","type":"gemini","model":"gemini-3.5-pro","content":"x","tokens":{"input":10,"output":\#(output),"total":\#(10 + output)}}"#
        }
        let lines = [
            #"{"sessionId":"s","projectHash":"h","startTime":"2026-11-25T01:59:00Z","kind":"main"}"#,
            #"{"$set":{"messages":[\#(msg("m1", 5))],"lastUpdated":"2026-11-25T02:00:00Z"}}"#,
            msg("m1", 5),
            msg("m2", 7),
            #"{"$patch":{"id":"m2","content":"y"}}"#,
            #"{"$rewindTo":"m2"}"#,
        ]
        let events = try XCTUnwrap(StatusService.geminiUsageEvents(
            data: Data(lines.joined(separator: "\n").utf8), isJSONL: true))
        XCTAssertEqual(events.map(\.tokens), [15, 17])
        XCTAssertEqual(Set(events.map(\.model)), ["gemini-3.5-pro"])
    }

    func testParsesGeminiSessionUsageEvents() throws {
        let data = Data("""
        {
          "sessionId": "sess-1",
          "messages": [
            {
              "id": "m1",
              "type": "gemini",
              "timestamp": "2026-07-13T09:00:00Z",
              "model": "gemini-2.5-pro",
              "tokens": {
                "input": 1000,
                "cached": 400,
                "output": 200,
                "thoughts": 50,
                "tool": 10,
                "total": 1260
              }
            }
          ]
        }
        """.utf8)
        let events = try XCTUnwrap(StatusService.geminiUsageEvents(data: data))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gemini-2.5-pro")
        XCTAssertEqual(events[0].tokens, 1260)
        XCTAssertEqual(events[0].categories["input"], 610)
        XCTAssertEqual(events[0].categories["cache_read"], 400)
        XCTAssertEqual(events[0].categories["output"], 200)
        XCTAssertEqual(events[0].categories["reasoning"], 50)
    }

    func testBridgeSnapshotIncludesGeminiAndMenuBarWeeklyMax() throws {
        var snapshot = BridgeSnapshot()
        snapshot.gemini.state = "working"
        snapshot.gemini.primary.percent = 35
        snapshot.gemini.weekly.percent = 82
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any]
        )
        let gemini = try XCTUnwrap(json["gemini"] as? [String: Any])
        XCTAssertEqual(gemini["status"] as? String, "working")
        XCTAssertEqual(gemini["primary_pct"] as? Double, 35)
        XCTAssertEqual(gemini["weekly_pct"] as? Double, 82)
        XCTAssertEqual(
            MenuBarController.menuBarWeeklyPercent(
                claudeWeekly: 40, codexWeekly: 55, geminiWeekly: 82
            ),
            82
        )
    }

    func testParsesAntigravityStatuslineGeminiQuota() {
        let now = Date(timeIntervalSince1970: 1_783_933_200) // 2026-07-13T09:00:00Z
        let payload: [String: Any] = [
            "product": "antigravity",
            "quota": [
                "gemini-5h": [
                    "remaining_fraction": 0.85,
                    "reset_time": "2026-07-13T12:00:00Z",
                    "reset_in_seconds": 10800,
                ],
                "gemini-weekly": [
                    "remaining_fraction": 0.9378,
                    "reset_time": "2026-07-18T09:00:00Z",
                    "reset_in_seconds": 432000,
                ],
                "3p-5h": [
                    "remaining_fraction": 1.0,
                    "reset_time": "2026-07-13T14:00:00Z",
                    "reset_in_seconds": 17999,
                ],
                "3p-weekly": [
                    "remaining_fraction": 1.0,
                    "reset_time": "2026-07-20T09:00:00Z",
                    "reset_in_seconds": 604799,
                ],
                "claude-sonnet": [
                    "remaining_fraction": 0.1,
                    "reset_time": "2026-07-13T11:00:00Z",
                ],
            ],
        ]
        let usage = UsageFetcher.antigravityStatuslineGeminiUsage(payload, fetchedAt: now, now: now)
        XCTAssertEqual(usage.primary.percent ?? -1, 15.0, accuracy: 0.01)
        XCTAssertEqual(usage.primary.resetMinutes, 180)
        XCTAssertEqual(usage.weekly.percent ?? -1, 6.22, accuracy: 0.01)
        XCTAssertEqual(usage.weekly.resetMinutes, 5 * 24 * 60)
        XCTAssertTrue(usage.scopedLimits.isEmpty)
    }

    func testParsesAntigravityTranscriptUsageAndPricesGeminiModels() throws {
        let jsonl = """
        {"step_index": 0, "type": "USER_INPUT", "created_at": "2026-11-25T02:19:20Z"}
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-25T02:19:29Z", "model": "gemini-4-neon-medium", "input_tokens": 1000000, "cache_read_tokens": 1000000, "output_tokens": 100000}
        {"step_index": 2, "type": "PLANNER_RESPONSE", "created_at": "2026-11-25T02:19:35Z", "model": "claude-opus-5-5", "input_tokens": 500000, "cache_read_tokens": 0, "output_tokens": 50000}
        """
        let events = try XCTUnwrap(
            StatusService.geminiUsageEvents(data: Data(jsonl.utf8), isJSONL: true)
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gemini-4-neon")
        XCTAssertEqual(events[0].tokens, 2_100_000)
        // 1M input ($3.00) + 1M cache_read ($0.15) + 0.1M output ($1.50) = $4.65
        let cost = try XCTUnwrap(
            Pricing.cost(model: events[0].model, categories: events[0].categories, table: Pricing.builtIn)
        )
        XCTAssertEqual(cost, 4.65, accuracy: 0.001)
    }
}
