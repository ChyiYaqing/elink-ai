import XCTest
@testable import ElinkAIBridge

/// `runCLI` 的死锁与超时行为。这里的每个用例都针对旧实现的一种卡死方式：
/// 旧代码先 `waitUntilExit()` 再读管道，任一管道写满内核缓冲区就双方互等。
final class UpdateCheckerCLITests: XCTestCase {
    private func sh(_ script: String) -> (URL, [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", script])
    }

    /// 单个管道就足以撑爆缓冲区：1MB 远超 64KB。
    func testLargeStdoutDoesNotDeadlock() throws {
        let (exe, args) = sh("dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr '\\0' 'x'")
        let outcome = try UpdateChecker.runCLI(exe, arguments: args, timeout: 20)

        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.stdout.count, 1024 * 1024)
    }

    /// 只排空 stdout 是不够的：stderr 写满同样会卡住子进程。
    func testLargeStderrDoesNotDeadlock() throws {
        let (exe, args) = sh("dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr '\\0' 'y' >&2")
        let outcome = try UpdateChecker.runCLI(exe, arguments: args, timeout: 20)

        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.stderr.count, 1024 * 1024)
    }

    /// 两个管道同时逼近上限，只有并发排空才能过。
    func testLargeOutputOnBothPipesDoesNotDeadlock() throws {
        let (exe, args) = sh("""
            dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\0' 'x'
            dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\0' 'y' >&2
            """)
        let outcome = try UpdateChecker.runCLI(exe, arguments: args, timeout: 20)

        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.stdout.count, 512 * 1024)
        XCTAssertEqual(outcome.stderr.count, 512 * 1024)
    }

    /// 挂死的子进程必须被超时收掉，否则 isChecking 永远回不到 false。
    /// 忽略 SIGTERM 是刻意的：只有 SIGKILL 能保证管道 EOF。
    func testHangingChildIsKilledByTimeout() throws {
        let start = Date()
        let outcome = try UpdateChecker.runCLI(
            URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", #"$SIG{TERM} = "IGNORE"; sleep 30"#],
            timeout: 0.3
        )

        XCTAssertTrue(outcome.timedOut)
        XCTAssertNotEqual(outcome.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// 正常退出的失败要保留 stderr 详情，供 CheckError.githubCLI 展示。
    func testNonZeroExitKeepsStderrDetail() throws {
        let (exe, args) = sh("echo 'gh: not authenticated' >&2; exit 4")
        let outcome = try UpdateChecker.runCLI(exe, arguments: args, timeout: 20)

        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, 4)
        XCTAssertEqual(String(data: outcome.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), "gh: not authenticated")
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(
            try UpdateChecker.runCLI(URL(fileURLWithPath: "/nonexistent/gh"),
                                     arguments: [], timeout: 5)
        )
    }
}
