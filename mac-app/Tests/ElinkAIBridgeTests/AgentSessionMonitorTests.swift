import XCTest
@testable import ElinkAIBridge

final class AgentSessionMonitorTests: XCTestCase {
    private var claudeRoot: URL!
    private var codexRoot: URL!

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elink-agent-sessions-\(UUID().uuidString)")
        claudeRoot = base.appendingPathComponent("claude/projects")
        codexRoot = base.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    /// NSTemporaryDirectory 是 /var → /private/var 的符号链接，而扫描器
    /// 返回的路径是规范化后的形式，比较路径前先统一规范化。
    private func canonicalPath(_ url: URL) throws -> String {
        try XCTUnwrap(url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeRoot.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func scanner() -> SessionScanner {
        SessionScanner(claudeRoot: claudeRoot, codexRoot: codexRoot)
    }

    @discardableResult
    private func write(_ lines: [String], to relativePath: String, under root: URL,
                       mtime: Date? = nil) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        return file
    }

    // MARK: - Claude transcript 解析

    func testClaudeTranscriptTailParsing() throws {
        let userTime = Date().addingTimeInterval(-120)
        let assistantTime = Date().addingTimeInterval(-60)
        try write([
            #"{"type":"user","message":{"content":"帮我修复 bug"},"timestamp":"\#(Self.iso.string(from: userTime))"}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-4","content":[{"type":"text","text":"已修复"}]},"timestamp":"\#(Self.iso.string(from: assistantTime))"}"#,
            #"{"type":"system","subtype":"away_summary","timestamp":"\#(Self.iso.string(from: Date()))"}"#,
        ], to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)

        let sessions = scanner().scan(live: [], claudeCwdCounts: [:])
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.kind, .claude)
        XCTAssertEqual(s.title, "myproj")
        XCTAssertEqual(s.prompt, "帮我修复 bug")
        XCTAssertEqual(s.snippet, "已修复")
        XCTAssertEqual(s.model, "opus-4")
        // system 条目不算活动：lastActivity 应是 assistant 的时间戳
        let activity = try XCTUnwrap(s.lastActivity)
        XCTAssertEqual(activity.timeIntervalSince1970,
                       assistantTime.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(s.isLive)
    }

    func testClaudeSubagentScan() throws {
        let now = Self.iso.string(from: Date())
        try write([
            #"{"type":"user","message":{"content":"主任务"},"timestamp":"\#(now)"}"#,
        ], to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)
        try write([
            #"{"type":"user","message":{"content":"research the API"},"timestamp":"\#(now)"}"#,
        ], to: "-Users-me-myproj/sess/subagents/agent-1.jsonl", under: claudeRoot)

        let sessions = scanner().scan(live: [], claudeCwdCounts: ["-Users-me-myproj": 1])
        let s = try XCTUnwrap(sessions.first)
        XCTAssertTrue(s.isLive)
        XCTAssertEqual(s.children.count, 1)
        let child = try XCTUnwrap(s.children.first)
        XCTAssertEqual(child.nickname, "research the API")
        // 子代理共享父进程：存活继承
        XCTAssertTrue(child.isLive)
    }

    // MARK: - Codex 分组

    func testCodexGroupingByParentThread() throws {
        let now = Self.iso.string(from: Date())
        try write([
            #"{"payload":{"id":"root-1","cwd":"/Users/me/myproj"}}"#,
            #"{"payload":{"type":"user_message","message":"do stuff"},"timestamp":"\#(now)"}"#,
        ], to: "rollout-2026-07-22T10-00-00-aaa.jsonl", under: codexRoot)
        let childFile = try write([
            #"{"payload":{"id":"child-1","parent_thread_id":"root-1","cwd":"/Users/me/myproj","source":{"subagent":{"thread_spawn":{"agent_nickname":"researcher"}}}}}"#,
            #"{"payload":{"type":"user_message","message":"sub task"},"timestamp":"\#(now)"}"#,
        ], to: "rollout-2026-07-22T10-01-00-bbb.jsonl", under: codexRoot)

        // 只有子 rollout 的 fd 被持有：整个线程组仍应判活
        let sessions = scanner().scan(live: [try canonicalPath(childFile)], claudeCwdCounts: [:])
        XCTAssertEqual(sessions.count, 1)
        let root = try XCTUnwrap(sessions.first)
        XCTAssertEqual(root.threadID, "root-1")
        XCTAssertEqual(root.title, "myproj")
        XCTAssertTrue(root.isLive)
        XCTAssertEqual(root.children.count, 1)
        let child = try XCTUnwrap(root.children.first)
        XCTAssertEqual(child.nickname, "researcher")
        XCTAssertTrue(child.isLive)
    }

    // MARK: - 过期过滤

    func testSessionsOlderThanSixHoursDropped() throws {
        let old = Date().addingTimeInterval(-7 * 3600)
        let stamp = Self.iso.string(from: old)
        try write([
            #"{"type":"user","message":{"content":"旧会话"},"timestamp":"\#(stamp)"}"#,
        ], to: "-Users-me-oldproj/sess.jsonl", under: claudeRoot, mtime: old)
        try write([
            #"{"payload":{"id":"old-1","cwd":"/Users/me/oldproj"}}"#,
        ], to: "rollout-old.jsonl", under: codexRoot, mtime: old)

        XCTAssertTrue(scanner().scan(live: [], claudeCwdCounts: [:]).isEmpty)
    }

    // MARK: - busy/live 派生

    func testBusyLiveDerivation() {
        var s = AgentSession(id: "/t", kind: .claude, title: "t", snippet: "",
                             model: "", lastModified: Date())
        s.lastActivity = Date()
        XCTAssertFalse(s.isBusy, "未存活不可能 busy")

        s.isLive = true
        XCTAssertTrue(s.isBusy)

        s.lastActivity = Date().addingTimeInterval(-60)
        s = withModified(s, lastModified: Date().addingTimeInterval(-60))
        XCTAssertFalse(s.isBusy, "存活但 30 秒无活动是空闲")
        XCTAssertTrue(s.isLive)

        var child = AgentSession(id: "/c", kind: .claude, title: "c", snippet: "",
                                 model: "", lastModified: Date())
        child.isLive = true
        child.lastActivity = Date()
        var parent = AgentSession(id: "/p", kind: .claude, title: "p", snippet: "",
                                  model: "", lastModified: Date().addingTimeInterval(-3600))
        parent.children = [child]
        XCTAssertTrue(parent.anyLive)
        XCTAssertTrue(parent.anyBusy)
        XCTAssertFalse(parent.isBusy)
    }

    private func withModified(_ s: AgentSession, lastModified: Date) -> AgentSession {
        var out = AgentSession(id: s.id, kind: s.kind, title: s.title, snippet: s.snippet,
                               model: s.model, lastModified: lastModified)
        out.isLive = s.isLive
        out.lastActivity = s.lastActivity
        return out
    }

    // MARK: - 存活跟踪

    func testLivenessTrackerRemovesAfterTwoMisses() {
        var tracker = LivenessTracker()
        let snap = ProcessDiscovery.Snapshot(kind: .codex, transcriptPath: "/a.jsonl", cwd: nil)

        XCTAssertTrue(tracker.update(snapshots: [snap]).live.contains("/a.jsonl"))
        // 第一次未见：宽限期内仍视为存活
        XCTAssertTrue(tracker.update(snapshots: []).live.contains("/a.jsonl"))
        // 连续第二次未见：移除
        XCTAssertFalse(tracker.update(snapshots: []).live.contains("/a.jsonl"))

        // 一次未见后重现：计数清零，仍存活
        _ = tracker.update(snapshots: [snap])
        _ = tracker.update(snapshots: [])
        XCTAssertTrue(tracker.update(snapshots: [snap]).live.contains("/a.jsonl"))
        XCTAssertTrue(tracker.update(snapshots: []).live.contains("/a.jsonl"))
    }

    func testLivenessTrackerClaudeCwdFallbackKeys() {
        var tracker = LivenessTracker()
        let snap = ProcessDiscovery.Snapshot(kind: .claude, transcriptPath: nil, cwd: "/Users/me/myproj")
        let result = tracker.update(snapshots: [snap, snap])
        XCTAssertTrue(result.live.isEmpty)
        XCTAssertEqual(result.claudeCwdCounts["-Users-me-myproj"], 2)
    }

    func testClaudeCwdFallbackMarksNewestTranscriptsLive() throws {
        let now = Self.iso.string(from: Date())
        let line = #"{"type":"user","message":{"content":"hi"},"timestamp":"\#(now)"}"#
        try write([line], to: "-Users-me-myproj/older.jsonl", under: claudeRoot,
                  mtime: Date().addingTimeInterval(-600))
        let newer = try write([line], to: "-Users-me-myproj/newer.jsonl", under: claudeRoot,
                              mtime: Date().addingTimeInterval(-10))

        let sessions = scanner().scan(live: [], claudeCwdCounts: ["-Users-me-myproj": 1])
        XCTAssertEqual(sessions.count, 2)
        let liveIDs = try sessions.filter(\.isLive).map { try canonicalPath(URL(fileURLWithPath: $0.id)) }
        XCTAssertEqual(liveIDs, [try canonicalPath(newer)])
    }

    func testClaudeCwdFallbackUsesClaudeProjectDirectoryEncoding() throws {
        let now = Self.iso.string(from: Date())
        try write([
            #"{"type":"user","message":{"content":"hi"},"timestamp":"\#(now)"}"#,
        ], to: "-Users-me-go-src-github-com-acme-my-api/sess.jsonl", under: claudeRoot)
        var tracker = LivenessTracker()
        let snapshot = ProcessDiscovery.Snapshot(
            kind: .claude, transcriptPath: nil,
            cwd: "/Users/me/go/src/github.com/acme/my_api")
        let tracked = tracker.update(snapshots: [snapshot])

        let session = try XCTUnwrap(scanner().scan(
            live: tracked.live,
            claudeCwdCounts: tracked.claudeCwdCounts
        ).first)
        XCTAssertTrue(session.isLive)
    }

    // MARK: - 设置开关

    func testAgentSessionsEnabledDefaultsOn() throws {
        let suite = "elink-agent-sessions-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AgentSessionMonitor.enabled(in: defaults))
        AgentSessionMonitor.setEnabled(false, in: defaults)
        XCTAssertFalse(AgentSessionMonitor.enabled(in: defaults))
        AgentSessionMonitor.setEnabled(true, in: defaults)
        XCTAssertTrue(AgentSessionMonitor.enabled(in: defaults))
    }

    // MARK: - 相对时间

    /// 折叠的卡片上，徽章只说忙不忙。有几个会话、上次动静多久以前，要靠副标题。
    func testCollapsedSubtitleCountsSessionsAndTheLatestActivity() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
        let now = Date()
        let old = AgentSession(id: "/a", kind: .claude, title: "a", snippet: "",
                               model: "", lastModified: now.addingTimeInterval(-7200))
        var recent = AgentSession(id: "/b", kind: .codex, title: "b", snippet: "",
                                  model: "", lastModified: now.addingTimeInterval(-3600))
        recent.lastActivity = now.addingTimeInterval(-300)

        XCTAssertEqual(AgentSessionsCard.subtitle(sessions: [old], now: now),
                       "1 session · last active 2h")
        // 取最近的那一个，而不是列表里的第一个
        XCTAssertEqual(AgentSessionsCard.subtitle(sessions: [old, recent], now: now),
                       "2 sessions · last active 5m")
        XCTAssertEqual(AgentSessionsCard.subtitle(sessions: [], now: now), "0 sessions")
    }

    func testRelativeTimeFormatting() {
        let now = Date()
        XCTAssertEqual(AgentSessionsCard.relativeTime(now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(AgentSessionsCard.relativeTime(now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(AgentSessionsCard.relativeTime(now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(AgentSessionsCard.relativeTime(now.addingTimeInterval(-2 * 86_400), now: now), "2d")
    }

    // MARK: - 子进程超时

    private func liveThreadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    /// 忽略 SIGTERM 的单进程，对应 lsof 卡在内核态时 `terminate()` 无效的真实故障。
    /// 用 sleep 复现不出问题：它会乖乖响应 SIGTERM，掩盖掉这里要守住的不变量。
    private static let stubbornChild = ["-e", #"$SIG{TERM} = "IGNORE"; sleep 30"#]

    func testRunTimesOutPromptlyEvenWhenChildIgnoresSIGTERM() {
        let start = Date()
        XCTAssertNil(ProcessDiscovery().run("/usr/bin/perl", Self.stubbornChild, timeout: 0.2))
        // 只有 SIGKILL 能让管道立刻 EOF；靠 SIGTERM 会一路拖满 30 秒
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// 每次超时漏掉一个全局池线程时，漏满 64 个软上限后整个 app 都会饿死。
    func testRepeatedTimeoutsDoNotLeakThreads() {
        let discovery = ProcessDiscovery()
        for _ in 0..<3 { _ = discovery.run("/usr/bin/perl", Self.stubbornChild, timeout: 0.05) }
        let baseline = liveThreadCount()

        for _ in 0..<70 { _ = discovery.run("/usr/bin/perl", Self.stubbornChild, timeout: 0.05) }

        XCTAssertLessThan(liveThreadCount() - baseline, 16)
        // 池子仍然健康的最终判据：超时之后普通命令依旧跑得通
        XCTAssertEqual(discovery.run("/bin/echo", ["ok"], timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}
