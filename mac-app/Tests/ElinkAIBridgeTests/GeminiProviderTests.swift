import XCTest
@testable import ElinkAIBridge

final class GeminiProviderTests: XCTestCase {
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
}
