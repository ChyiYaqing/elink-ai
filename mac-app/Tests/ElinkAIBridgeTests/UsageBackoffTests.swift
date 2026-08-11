import XCTest
@testable import ElinkAIBridge

/// 限流退避。此前退避硬编码 300 秒，加上 120 秒 timer 得到 360 秒的实际重试
/// 间隔，而服务端要求 414 秒 —— 每次重试都落在窗口内，跨两天 25 次请求无一
/// 成功。这些用例守住「服务端说多久就等多久」。
final class UsageBackoffTests: XCTestCase {
    // MARK: - Retry-After 解析

    func testParsesDeltaSeconds() {
        XCTAssertEqual(UsageFetcher.retryAfterSeconds("414"), 414)
        XCTAssertEqual(UsageFetcher.retryAfterSeconds("  30  "), 30)
    }

    func testParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(120))

        let parsed = try? XCTUnwrap(UsageFetcher.retryAfterSeconds(header, now: now))
        XCTAssertEqual(parsed ?? 0, 120, accuracy: 1)
    }

    /// 解析不出来必须退回默认退避，绝不能当作 0 立即重试。
    func testUnusableValuesYieldNil() {
        XCTAssertNil(UsageFetcher.retryAfterSeconds(nil))
        XCTAssertNil(UsageFetcher.retryAfterSeconds(""))
        XCTAssertNil(UsageFetcher.retryAfterSeconds("   "))
        XCTAssertNil(UsageFetcher.retryAfterSeconds("soon"))
        XCTAssertNil(UsageFetcher.retryAfterSeconds("0"))
        XCTAssertNil(UsageFetcher.retryAfterSeconds("-5"))
        // 已经过去的 HTTP-date 同样不可用
        let past = "Sun, 06 Nov 1994 08:49:37 GMT"
        XCTAssertNil(UsageFetcher.retryAfterSeconds(past, now: Date()))
    }

    // MARK: - 退避计算

    func testServerValueWins() {
        XCTAssertEqual(UsageFetcher.backoffInterval(retryAfter: 414, rateLimited: true), 419)
    }

    func testFallsBackWhenServerSaysNothing() {
        XCTAssertEqual(UsageFetcher.backoffInterval(retryAfter: nil, rateLimited: true), 300)
        XCTAssertEqual(UsageFetcher.backoffInterval(retryAfter: nil, rateLimited: false), 60)
    }

    func testClampsBothEnds() {
        XCTAssertEqual(UsageFetcher.backoffInterval(retryAfter: 1, rateLimited: true), 60)
        XCTAssertEqual(UsageFetcher.backoffInterval(retryAfter: 86_400, rateLimited: true), 3600)
    }

    /// 生产实测值：服务端 414 秒，旧实现实际每 360 秒重试一次。
    /// 新的退避必须真正越过那个窗口，否则修了等于没修。
    func testObservedProductionCaseEscapesTheWindow() {
        let observedRetryAfter: TimeInterval = 414
        let oldEffectiveInterval: TimeInterval = 360

        let backoff = UsageFetcher.backoffInterval(retryAfter: observedRetryAfter, rateLimited: true)

        XCTAssertGreaterThan(backoff, observedRetryAfter)
        XCTAssertGreaterThan(backoff, oldEffectiveInterval)
    }

    func testForcedRefreshDuringFetchRunsAgainBeforeCompleting() {
        let firstRequestStarted = expectation(description: "first request started")
        let firstCompletion = expectation(description: "first completion")
        let forcedCompletion = expectation(description: "forced completion")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let counterLock = NSLock()
        var claudeRequests = 0

        let validUsage = Data(#"{"five_hour":{"utilization":11,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":22,"resets_at":"2099-01-02T00:00:00Z"}}"#.utf8)
        let fetcher = UsageFetcher(
            claudeTokenProvider: { .success("test-claude-token") },
            requestHandler: { request in
                guard request.url?.host == "api.anthropic.com" else {
                    return UsageFetcher.HTTPOutcome(data: Data("{}".utf8), status: 401, retryAfter: nil)
                }
                let requestNumber = counterLock.holding { () -> Int in
                    claudeRequests += 1
                    return claudeRequests
                }
                if requestNumber == 1 {
                    firstRequestStarted.fulfill()
                    _ = releaseFirstRequest.wait(timeout: .now() + 3)
                    return UsageFetcher.HTTPOutcome(data: Data(), status: 401, retryAfter: nil)
                }
                return UsageFetcher.HTTPOutcome(data: validUsage, status: 200, retryAfter: nil)
            }
        )

        fetcher.refresh { firstCompletion.fulfill() }
        wait(for: [firstRequestStarted], timeout: 2)
        fetcher.refresh(force: true) { forcedCompletion.fulfill() }
        releaseFirstRequest.signal()
        wait(for: [firstCompletion, forcedCompletion], timeout: 5)

        XCTAssertEqual(counterLock.holding { claudeRequests }, 2)
        XCTAssertEqual(fetcher.claude.primary.percent, 11)
        XCTAssertEqual(fetcher.claude.weekly.percent, 22)
    }
}
