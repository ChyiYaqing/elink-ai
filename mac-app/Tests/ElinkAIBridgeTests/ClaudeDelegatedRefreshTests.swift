import XCTest
@testable import ElinkAIBridge

/// 委托刷新。Claude Code 惰性续期，空闲会话不刷新 Keychain，面板此前会在
/// 「token 过期」到「用户下次真的用一下 claude」之间一直显示过期（实测 32 分钟）。
/// 这些用例守住那条补救路径的判定逻辑。
final class ClaudeDelegatedRefreshTests: XCTestCase {
    // MARK: - 冷却

    func testCooldownBlocksBackgroundAttempts() {
        let now = Date()
        XCTAssertFalse(ClaudeDelegatedRefresh.shouldAttempt(
            now: now, nextAllowed: now.addingTimeInterval(60), userInitiated: false))
        XCTAssertTrue(ClaudeDelegatedRefresh.shouldAttempt(
            now: now, nextAllowed: now.addingTimeInterval(-1), userInitiated: false))
    }

    /// 用户盯着面板点刷新时必须立刻试一次，否则冷却期内他只能干等。
    func testUserInitiatedBypassesCooldown() {
        let now = Date()
        XCTAssertTrue(ClaudeDelegatedRefresh.shouldAttempt(
            now: now, nextAllowed: now.addingTimeInterval(600), userInitiated: true))
    }

    /// 失败冷却必须明显长于成功冷却：续不上多半是 refresh token 也废了，
    /// 按 120 秒的刷新节奏反复起 claude 只是白烧进程。
    func testFailureCooldownOutlastsSuccessCooldown() {
        XCTAssertGreaterThan(ClaudeDelegatedRefresh.failureCooldown,
                             ClaudeDelegatedRefresh.successCooldown)
    }

    // MARK: - 启动环境

    /// 带着 API key 或长期 token 启动的 claude 走另一条鉴权路径，压根不会去碰
    /// OAuth 凭据——不清掉这些变量，这一趟就是白跑。
    func testTouchEnvironmentDropsCompetingCredentials() {
        let environment = ClaudeDelegatedRefresh.touchEnvironment(base: [
            "PATH": "/usr/bin",
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-long-lived",
            "ANTHROPIC_API_KEY": "sk-ant-api03-key",
            "ANTHROPIC_BASE_URL": "https://example.invalid",
        ])

        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    /// 被动探针不该顺手把用户的 claude 升级掉。
    func testTouchEnvironmentDisablesAutoUpdater() {
        XCTAssertEqual(
            ClaudeDelegatedRefresh.touchEnvironment(base: [:])["DISABLE_AUTOUPDATER"], "1")
    }

    // MARK: - 二进制解析

    func testClaudeBinaryPrefersTheFirstExecutableCandidate() {
        let home = NSHomeDirectory()
        let resolved = ClaudeDelegatedRefresh.claudeBinary(
            candidates: ["~/.local/bin/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" }
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/claude")

        let tilde = ClaudeDelegatedRefresh.claudeBinary(
            candidates: ["~/.local/bin/claude"],
            isExecutable: { $0 == home + "/.local/bin/claude" }
        )
        XCTAssertEqual(tilde, home + "/.local/bin/claude")
    }

    func testClaudeBinaryReturnsNilWhenNothingIsInstalled() {
        XCTAssertNil(ClaudeDelegatedRefresh.claudeBinary(
            candidates: ["~/.local/bin/claude"], isExecutable: { _ in false }))
    }

    // MARK: - 与用量刷新的接线

    private struct Probe {
        let lock = NSLock()
        final class State {
            var tokenReads = 0
            var refreshCalls = 0
            var userInitiated: [Bool] = []
            var claudeRequests = 0
        }
        let state = State()
    }

    private func makeFetcher(
        renewSucceeds: Bool,
        initialError: UsageFetcher.CredentialError = .expiredClaudeCredentials,
        probe: Probe
    ) -> UsageFetcher {
        let usage = Data(#"{"five_hour":{"utilization":7,"resets_at":"2099-01-01T00:00:00Z"}}"#.utf8)
        return UsageFetcher(
            claudeTokenProvider: {
                let reads = probe.lock.holding { () -> Int in
                    probe.state.tokenReads += 1
                    return probe.state.tokenReads
                }
                // 第一次读到过期凭据；委托刷新成功后 Claude Code 已经把新 token
                // 写回 Keychain，所以第二次应该读到可用的那份。
                if reads == 1 { return .failure(initialError) }
                return renewSucceeds ? .success("renewed-token") : .failure(initialError)
            },
            claudeRefresher: { userInitiated in
                probe.lock.holding {
                    probe.state.refreshCalls += 1
                    probe.state.userInitiated.append(userInitiated)
                }
                return renewSucceeds
            },
            requestHandler: { request in
                guard request.url?.host == "api.anthropic.com" else {
                    return UsageFetcher.HTTPOutcome(data: Data("{}".utf8), status: 401, retryAfter: nil)
                }
                probe.lock.holding { probe.state.claudeRequests += 1 }
                return UsageFetcher.HTTPOutcome(data: usage, status: 200, retryAfter: nil)
            }
        )
    }

    func testExpiredCredentialTriggersDelegatedRefreshAndRetries() {
        let probe = Probe()
        let fetcher = makeFetcher(renewSucceeds: true, probe: probe)

        let done = expectation(description: "refresh finished")
        fetcher.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(probe.lock.holding { probe.state.refreshCalls }, 1)
        XCTAssertEqual(probe.lock.holding { probe.state.claudeRequests }, 1)
        XCTAssertEqual(fetcher.claude.primary.percent, 7)
        XCTAssertNil(fetcher.claude.error)
    }

    /// 续不上就别发那次注定 401 的请求：401 之后的重试会被限流，而 429 的退避
    /// 最长能拖到一小时，面板只能一直显示 statusline 缓存。
    func testFailedRenewalSkipsTheDoomedUsageRequest() {
        let probe = Probe()
        let fetcher = makeFetcher(renewSucceeds: false, probe: probe)

        let done = expectation(description: "refresh finished")
        fetcher.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(probe.lock.holding { probe.state.refreshCalls }, 1)
        XCTAssertEqual(probe.lock.holding { probe.state.claudeRequests }, 0)
        XCTAssertEqual(probe.lock.holding { probe.state.tokenReads }, 1)
    }

    /// 凭据根本不存在或格式坏了，起一次 claude 也刷不出东西来——那种情况只能
    /// 重新登录，不该白起一个进程。
    func testNonExpiredCredentialFailureDoesNotTouchClaude() {
        let probe = Probe()
        let fetcher = makeFetcher(
            renewSucceeds: true, initialError: .invalidClaudeCredentials, probe: probe)

        let done = expectation(description: "refresh finished")
        fetcher.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(probe.lock.holding { probe.state.refreshCalls }, 0)
        XCTAssertEqual(probe.lock.holding { probe.state.claudeRequests }, 0)
    }

    /// 用户主动刷新必须以 userInitiated 的身份传下去，否则冷却期内点了也没反应。
    func testForcedRefreshIsReportedAsUserInitiated() {
        let probe = Probe()
        let fetcher = makeFetcher(renewSucceeds: true, probe: probe)

        let done = expectation(description: "refresh finished")
        fetcher.refresh(force: true) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(probe.lock.holding { probe.state.userInitiated }, [true])
    }

    func testBackgroundRefreshIsNotReportedAsUserInitiated() {
        let probe = Probe()
        let fetcher = makeFetcher(renewSucceeds: true, probe: probe)

        let done = expectation(description: "refresh finished")
        fetcher.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(probe.lock.holding { probe.state.userInitiated }, [false])
    }
}
