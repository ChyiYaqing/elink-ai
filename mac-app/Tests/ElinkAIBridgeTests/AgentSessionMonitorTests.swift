import XCTest
@testable import ElinkAIBridge

final class AgentSessionMonitorTests: XCTestCase {
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private var geminiRoot: URL!
    private var antigravityRoot: URL!

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
        geminiRoot = base.appendingPathComponent("gemini/tmp")
        antigravityRoot = base.appendingPathComponent("gemini/antigravity-cli/brain")
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
        // Gemini 两个根目录也指向临时目录，否则会扫到本机真实会话
        SessionScanner(claudeRoot: claudeRoot, codexRoot: codexRoot,
                       geminiRoot: geminiRoot, antigravityRoots: [antigravityRoot])
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

    /// 展开区按时间正序列出对话与工具活动；thinking 与 tool_result 不进列表。
    func testClaudeTranscriptRowsInOrder() throws {
        let now = Self.iso.string(from: Date())
        let longPrompt = String(repeating: "详细需求。", count: 40)
        try write([
            #"{"type":"user","message":{"content":"\#(longPrompt)"},"timestamp":"\#(now)"}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"thinking","thinking":"内部推理"},{"type":"text","text":"第一段\n第二段"}]},"timestamp":"\#(now)"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/me/myproj/App.swift"}}]},"timestamp":"\#(now)"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"文件内容"}]},"timestamp":"\#(now)"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test --filter X","description":"跑测试"}}]},"timestamp":"\#(now)"}"#,
        ], to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertTrue(AgentSessionsCard.hasTranscript(s))
        XCTAssertEqual(s.transcript.map(\.role), [.user, .assistant, .tool, .tool])
        // 展开区保留完整正文与换行，折叠行仍是压扁的 90 字符单行
        XCTAssertEqual(s.transcript[1].text, "第一段\n第二段")
        XCTAssertGreaterThan(s.transcript[0].text.count, s.prompt.count)
        // 工具行：路径只留文件名，Bash 优先用比命令更可读的 description
        XCTAssertEqual(s.transcript[2].title, "Read")
        XCTAssertEqual(s.transcript[2].text, "App.swift")
        XCTAssertEqual(s.transcript[3].text, "跑测试")
        // id 要稳定且互不相同，否则滚动区每次 poll 都会错位
        XCTAssertEqual(Set(s.transcript.map(\.id)).count, s.transcript.count)
        let again = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertEqual(again.transcript.map(\.id), s.transcript.map(\.id))
    }

    func testCodexTranscriptRows() throws {
        let now = Self.iso.string(from: Date())
        try write([
            #"{"payload":{"id":"root-1","cwd":"/Users/me/myproj"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"跑一下测试"},"timestamp":"\#(now)"}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"pytest -q\"})"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"测试已通过"},"timestamp":"\#(now)"}"#,
        ], to: "rollout-2026-07-22T10-00-00-aaa.jsonl", under: codexRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertEqual(s.transcript.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(s.transcript[0].text, "跑一下测试")
        XCTAssertEqual(s.transcript[1].title, "exec")
        XCTAssertEqual(s.transcript[2].text, "测试已通过")
    }

    /// 无界增长会让展开区越滚越慢，也会把 3 秒一次的解析成本推上去。
    func testTranscriptKeepsOnlyTheMostRecentEntries() throws {
        let now = Self.iso.string(from: Date())
        let lines = (0..<80).map {
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"第 \#($0) 条"}]},"timestamp":"\#(now)"}"#
        }
        try write(lines, to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertEqual(s.transcript.count, SessionScanner.maxTranscriptEntries)
        // 留下的必须是最近的那一批，不是最早的
        XCTAssertEqual(s.transcript.last?.text, "第 79 条")
    }

    // MARK: - 输出速率

    /// 同一条 message 按内容块拆成多行，中间还夹着流式执行的 tool_result：
    /// 起点必须是这条 message 之前的输入，而不是块之间的工具结果。
    func testClaudeOutputRateGroupsBlocksByMessageID() throws {
        let t0 = Date().addingTimeInterval(-100)
        func at(_ s: Double) -> String { Self.iso.string(from: t0.addingTimeInterval(s)) }
        try write([
            #"{"type":"user","message":{"content":"开始"},"timestamp":"\#(at(0))"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","stop_reason":"tool_use","usage":{"output_tokens":200},"content":[{"type":"thinking","thinking":""}]},"timestamp":"\#(at(4))"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","stop_reason":"tool_use","usage":{"output_tokens":200},"content":[{"type":"tool_use","name":"Read","input":{}}]},"timestamp":"\#(at(6))"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]},"timestamp":"\#(at(7))"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","stop_reason":"tool_use","usage":{"output_tokens":200},"content":[{"type":"tool_use","name":"Read","input":{}}]},"timestamp":"\#(at(10))"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]},"timestamp":"\#(at(12))"}"#,
            #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-5","stop_reason":"end_turn","usage":{"output_tokens":100},"content":[{"type":"text","text":"完成"}]},"timestamp":"\#(at(22))"}"#,
            // 错误占位消息不是真实的模型输出
            #"{"type":"assistant","message":{"id":"m3","model":"<synthetic>","stop_reason":"stop_sequence","usage":{"output_tokens":0},"content":[{"type":"text","text":"API Error"}]},"timestamp":"\#(at(23))"}"#,
        ], to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        // (200 + 100) tokens / (10s + 10s)
        XCTAssertEqual(try XCTUnwrap(s.tokensPerSecond), 15, accuracy: 0.001)
    }

    /// 旧版 Claude Code 写的是流式中途的 usage，拿来算会严重偏低。
    func testClaudeOutputRateIgnoresUsageWithoutStopReason() throws {
        let t0 = Date().addingTimeInterval(-100)
        func at(_ s: Double) -> String { Self.iso.string(from: t0.addingTimeInterval(s)) }
        try write([
            #"{"type":"user","message":{"content":"开始"},"timestamp":"\#(at(0))"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5","stop_reason":null,"usage":{"output_tokens":3},"content":[{"type":"text","text":"好"}]},"timestamp":"\#(at(20))"}"#,
        ], to: "-Users-me-myproj/sess.jsonl", under: claudeRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertNil(s.tokensPerSecond)
    }

    /// Codex 边流式输出边执行工具，工具结果可能在 token_usage_record 之前落盘。
    func testCodexOutputRateStartsBeforeTheResponsesFirstOutput() throws {
        let t0 = Date().addingTimeInterval(-100)
        func at(_ s: Double) -> String { Self.iso.string(from: t0.addingTimeInterval(s)) }
        try write([
            #"{"payload":{"id":"root-1","cwd":"/Users/me/myproj"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[]},"timestamp":"\#(at(0))"}"#,
            #"{"type":"response_item","payload":{"type":"reasoning"},"timestamp":"\#(at(5))"}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":""},"timestamp":"\#(at(6))"}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output"},"timestamp":"\#(at(7))"}"#,
            #"{"type":"token_usage_record","payload":{"usage":{"output_tokens":160}},"timestamp":"\#(at(8))"}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]},"timestamp":"\#(at(10))"}"#,
            #"{"type":"token_usage_record","payload":{"usage":{"output_tokens":40}},"timestamp":"\#(at(12))"}"#,
        ], to: "rollout-2026-07-22T10-00-00-aaa.jsonl", under: codexRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        // (160 + 40) tokens / (8s + 5s)
        XCTAssertEqual(try XCTUnwrap(s.tokensPerSecond), 200.0 / 13, accuracy: 0.001)
    }

    func testTagShowsOutputRateOnlyWhenKnown() {
        let now = Date()
        var s = AgentSession(id: "/a", kind: .claude, title: "proj", snippet: "",
                             model: "opus-5", lastModified: now)
        XCTAssertEqual(AgentSessionsCard.tagText(s, now: now), "opus-5 · now")
        s.tokensPerSecond = 57.6
        XCTAssertEqual(AgentSessionsCard.tagText(s, now: now), "opus-5 · 58 tok/s · now")
    }

    /// 没有正文可读时不该给出一个展开后是空的箭头。
    func testSessionWithoutTranscriptIsNotExpandable() {
        let s = AgentSession(id: "/a", kind: .claude, title: "a", snippet: "摘要",
                             model: "", lastModified: Date())
        XCTAssertFalse(AgentSessionsCard.hasTranscript(s))
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

    // MARK: - 解析缓存

    /// 大小与 mtime 都没变的文件不重读；任一变化都重新解析。
    func testUnchangedTranscriptReusesParsedTail() throws {
        let mtime = Date().addingTimeInterval(-60)
        let rel = "-Users-me-myproj/sess.jsonl"
        try write([#"{"type":"user","message":{"content":"第一版"}}"#],
                  to: rel, under: claudeRoot, mtime: mtime)
        let s = scanner()
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.prompt, "第一版")

        // 同样字节数、同样 mtime：命中缓存，仍是旧内容
        try write([#"{"type":"user","message":{"content":"第二版"}}"#],
                  to: rel, under: claudeRoot, mtime: mtime)
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.prompt, "第一版")

        // 追加内容：大小变了，重新解析
        try write([#"{"type":"user","message":{"content":"第二版"}}"#,
                   #"{"type":"user","message":{"content":"第三版"}}"#],
                  to: rel, under: claudeRoot, mtime: mtime)
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.prompt, "第三版")
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

    // MARK: - Gemini / Antigravity

    func testLivenessTrackerGeminiFallbackKeys() {
        var tracker = LivenessTracker()
        func cli(_ tty: String) -> ProcessDiscovery.Snapshot {
            ProcessDiscovery.Snapshot(kind: .gemini, transcriptPath: nil, cwd: "/Users/me/a#b", tty: tty)
        }
        let agy = ProcessDiscovery.Snapshot(kind: .gemini, transcriptPath: nil, cwd: "/x", antigravity: true)
        let result = tracker.update(snapshots: [cli("1"), cli("2"), agy, agy, agy])
        XCTAssertTrue(result.live.isEmpty)
        XCTAssertEqual(result.geminiCwdCounts, ["/Users/me/a#b": 2])
        XCTAssertEqual(result.antigravityCount, 3)
        XCTAssertTrue(result.claudeCwdCounts.isEmpty)
    }

    func testGeminiLivenessFollowsEachProcessMatch() {
        var tracker = LivenessTracker()
        let fallbackA = ProcessDiscovery.Snapshot(kind: .gemini, transcriptPath: nil, cwd: "/p", tty: "s001")
        let exactA = ProcessDiscovery.Snapshot(kind: .gemini, transcriptPath: "/s.json", cwd: "/p", tty: "s001")
        let fallbackB = ProcessDiscovery.Snapshot(kind: .gemini, transcriptPath: nil, cwd: "/p", tty: "s002")
        XCTAssertEqual(tracker.update(snapshots: [fallbackA]).geminiCwdCounts, ["/p": 1])
        // 同一进程打开了会话文件：只剩精确匹配，不再多占一个回退名额
        var result = tracker.update(snapshots: [exactA])
        XCTAssertEqual(result.live, ["/s.json"])
        XCTAssertTrue(result.geminiCwdCounts.isEmpty)
        // 反过来关掉会话文件：旧的精确匹配也不留
        result = tracker.update(snapshots: [fallbackA])
        XCTAssertTrue(result.live.isEmpty)
        XCTAssertEqual(result.geminiCwdCounts, ["/p": 1])
        // 同目录的另一个进程漏探一轮，仍按自己的宽限期保留
        _ = tracker.update(snapshots: [exactA, fallbackB])
        result = tracker.update(snapshots: [exactA])
        XCTAssertEqual(result.live, ["/s.json"])
        XCTAssertEqual(result.geminiCwdCounts, ["/p": 1])
        result = tracker.update(snapshots: [exactA])
        XCTAssertTrue(result.geminiCwdCounts.isEmpty)
    }

    func testGeminiCwdFallbackMatchesHashedAndNamedProjectDirectories() throws {
        let line = #"{"sessionId":"s","messages":[{"type":"user","content":"hi"}]}"#
        // 旧版：目录名是 cwd 的 sha256
        let hashed = "d2f01f8f40d3d60692694bafcc7b2ac97bf4dbec581bd35e9407df956fb4a1fa"
        try write([line], to: "\(hashed)/chats/session-old.json", under: geminiRoot,
                  mtime: Date().addingTimeInterval(-600))
        let hashedNewest = try write([line], to: "\(hashed)/chats/session-new.json", under: geminiRoot,
                                     mtime: Date().addingTimeInterval(-60))
        // 新版：projects.json 登记的短名
        try #"{"projects":{"/Users/me/named":"named"}}"#.write(
            to: geminiRoot.deletingLastPathComponent().appendingPathComponent("projects.json"),
            atomically: true, encoding: .utf8)
        let named = try write([line], to: "named/chats/session-1.json", under: geminiRoot,
                              mtime: Date().addingTimeInterval(-60))
        try write([line], to: "other/chats/session-1.json", under: geminiRoot,
                  mtime: Date().addingTimeInterval(-30))

        let sessions = scanner().scan(live: [], claudeCwdCounts: [:], geminiCwdCounts: [
            "/Users/chyiyaqing/chyi/github/elink-ai": 1,
            "/Users/me/named": 1,
        ])
        let liveIDs = try Set(sessions.filter(\.isLive).map { try canonicalPath(URL(fileURLWithPath: $0.id)) })
        XCTAssertEqual(liveIDs, [try canonicalPath(hashedNewest), try canonicalPath(named)])
    }

    func testExactlyLiveGeminiSessionDoesNotUseTheCwdFallbackSlot() throws {
        let line = #"{"sessionId":"s","messages":[{"type":"user","content":"hi"}]}"#
        let hashed = "d2f01f8f40d3d60692694bafcc7b2ac97bf4dbec581bd35e9407df956fb4a1fa"
        // 一个进程打开了最新会话，另一个进程只能按 cwd 匹配到次新的那个
        let older = try write([line], to: "\(hashed)/chats/session-older.json", under: geminiRoot,
                              mtime: Date().addingTimeInterval(-600))
        let newest = try write([line], to: "\(hashed)/chats/session-newest.json", under: geminiRoot,
                               mtime: Date().addingTimeInterval(-60))

        let sessions = scanner().scan(live: [try canonicalPath(newest)], claudeCwdCounts: [:], geminiCwdCounts: [
            "/Users/chyiyaqing/chyi/github/elink-ai": 1,
        ])
        let liveIDs = try Set(sessions.filter(\.isLive).map { try canonicalPath(URL(fileURLWithPath: $0.id)) })
        XCTAssertEqual(liveIDs, [try canonicalPath(newest), try canonicalPath(older)])
    }

    func testGeminiProcessMatchesOnlyTheExecutableOrNodeScript() {
        XCTAssertTrue(ProcessDiscovery.isGemini("gemini"))
        XCTAssertTrue(ProcessDiscovery.isGemini("/opt/homebrew/bin/gemini --resume"))
        XCTAssertTrue(ProcessDiscovery.isGemini("node /opt/homebrew/bin/gemini"))
        XCTAssertTrue(ProcessDiscovery.isGemini("node --inspect --max-old-space-size=4096 /opt/homebrew/bin/gemini"))
        XCTAssertTrue(ProcessDiscovery.isGemini("node --require node:fs /opt/homebrew/bin/gemini"))
        XCTAssertTrue(ProcessDiscovery.isGemini("node --diagnostic-dir /tmp /opt/homebrew/bin/gemini"))
        XCTAssertTrue(ProcessDiscovery.isGemini("node /x/@google/gemini-cli/bundle/gemini.js"))
        XCTAssertFalse(ProcessDiscovery.isGemini("vim gemini"))
        XCTAssertFalse(ProcessDiscovery.isGemini("grep -r gemini ."))
    }

    func testGeminiSnippetUnwrapsUserRequestAndKeepsMarkup() {
        XCTAssertEqual(SessionScanner.geminiSnippetText("<USER_REQUEST>\n修复问题\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"),
                       "修复问题")
        XCTAssertEqual(SessionScanner.geminiSnippetText("<div>真实回复</div>"), "<div>真实回复</div>")
        XCTAssertNil(SessionScanner.geminiSnippetText("<USER_SETTINGS_CHANGE>mode</USER_SETTINGS_CHANGE>"))
        XCTAssertNil(SessionScanner.geminiSnippetText("<session_context>..."))
        XCTAssertNil(SessionScanner.geminiSnippetText("<hook_context>from SessionStart</hook_context>"))
    }

    func testAntigravityTranscriptTitleIDAndActivity() throws {
        let created = Date().addingTimeInterval(-90)
        let ts = ISO8601DateFormatter().string(from: created)
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5))
        try write([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"\#(ts)","content":"补充 gemini"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(ts)","model":"gemini-4-neon","content":"已完成"}"#,
            #"{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","created_at":"\#(later)","content":"<SYSTEM_MESSAGE>"}"#,
        ], to: "conv-1/.system_generated/logs/transcript.jsonl", under: antigravityRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertEqual(s.kind, .gemini)
        XCTAssertEqual(s.title, "Antigravity")
        XCTAssertEqual(s.threadID, "conv-1")
        XCTAssertEqual(s.model, "gemini-4-neon")
        XCTAssertEqual(s.snippet, "已完成")
        // 系统注入行不算活动；活动时间来自 created_at 而不是 mtime
        let activity = try XCTUnwrap(s.lastActivity)
        XCTAssertEqual(activity.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
    }

    func testAntigravityProcessCountMarksNewestTranscriptsLive() throws {
        let line = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"hi"}"#
        try write([line], to: "old/.system_generated/logs/transcript.jsonl", under: antigravityRoot,
                  mtime: Date().addingTimeInterval(-600))
        let newest = try write([line], to: "new/.system_generated/logs/transcript.jsonl",
                               under: antigravityRoot, mtime: Date().addingTimeInterval(-10))

        let sessions = scanner().scan(live: [], claudeCwdCounts: [:], antigravityLive: 1)
        let liveIDs = try sessions.filter(\.isLive).map { try canonicalPath(URL(fileURLWithPath: $0.id)) }
        XCTAssertEqual(liveIDs, [try canonicalPath(newest)])
    }

    func testGeminiJSONLReplayFollowsSetPatchAndRewind() throws {
        let ts = Self.iso.string(from: Date().addingTimeInterval(-30))
        func msg(_ id: String, _ type: String, _ content: String) -> String {
            #"{"id":"\#(id)","timestamp":"\#(ts)","type":"\#(type)","model":"gemini-3.5-pro","content":\#(content)}"#
        }
        try write([
            #"{"sessionId":"sess-1","projectHash":"h","startTime":"\#(ts)","kind":"main","directories":["/Users/me/proj"]}"#,
            #"{"$set":{"messages":[\#(msg("ctx", "user", #"[{"text":"<session_context>..."}]"#))]}}"#,
            msg("u1", "user", #"[{"text":"修复 "},{"text":"bug"}]"#),
            msg("g1", "gemini", #""草稿""#),
            #"{"$patch":{"id":"g1","content":"已修复"}}"#,
            msg("u2", "user", #""这条会被回退""#),
            #"{"$rewindTo":"u2"}"#,
        ], to: "proj/chats/session-1.jsonl", under: geminiRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        XCTAssertEqual(s.title, "proj")
        XCTAssertEqual(s.threadID, "sess-1")
        XCTAssertEqual(s.model, "gemini-3.5-pro")
        XCTAssertEqual(s.snippet, "已修复")

        let (_, messages) = SessionScanner.replayGeminiLog([
            ["id": "a"], ["id": "b"], ["id": "c"],
            ["$patch": ["removeIds": ["b"], "orderIds": ["c", "a", "c"]]],
        ])
        XCTAssertEqual(messages.compactMap { $0["id"] as? String }, ["c", "a"])
    }

    func testGeminiCLIOutputRateCountsOutputAndThoughtsAcrossToolCalls() throws {
        let t0 = Date().addingTimeInterval(-100)
        func at(_ s: Double) -> String { Self.iso.string(from: t0.addingTimeInterval(s)) }
        let json = """
        {
          "sessionId": "sess-rate",
          "messages": [
            {"id":"u1","type":"user","timestamp":"\(at(0))","content":"code review"},
            {
              "id":"g1","type":"gemini","timestamp":"\(at(10))","model":"gemini-3-pro",
              "content":"checking files",
              "tokens":{"input":1000,"output":100,"thoughts":300,"cached":0,"tool":0,"total":1400},
              "toolCalls":[{"id":"t1","name":"read_file","timestamp":"\(at(12))"}]
            },
            {
              "id":"g2","type":"gemini","timestamp":"\(at(22))","model":"gemini-3-pro",
              "content":"done",
              "tokens":{"input":2000,"output":200,"thoughts":400,"cached":0,"tool":0,"total":2600}
            }
          ]
        }
        """
        try write([json], to: "proj/chats/session-rate.json", under: geminiRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        // (400 + 600) tokens / (10s + 10s) = 50 tok/s
        XCTAssertEqual(try XCTUnwrap(s.tokensPerSecond), 50, accuracy: 0.001)
        XCTAssertTrue(AgentSessionsCard.tagText(s, now: t0.addingTimeInterval(25)).contains("50 tok/s"))
    }

    func testAntigravityOutputRatePairsPlannerWithNextModelStepAndSkipsUserWait() throws {
        let t0 = Date().addingTimeInterval(-200)
        func at(_ s: Double) -> String { ISO8601DateFormatter().string(from: t0.addingTimeInterval(s)) }
        try write([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"\#(at(0))","content":"hi"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(at(0))","model":"gemini-4-neon-medium","output_tokens":300}"#,
            #"{"step_index":2,"source":"MODEL","type":"GENERIC","created_at":"\#(at(5))","content":"tool output"}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(at(6))","model":"gemini-4-neon-medium","output_tokens":700}"#,
            // 后面隔了 120 秒才是用户输入：这段等待不能算进模型生成耗时
            #"{"step_index":4,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"\#(at(126))","content":"next"}"#,
            #"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(at(126))","model":"gemini-4-neon-medium","output_tokens":500}"#,
            #"{"step_index":6,"source":"MODEL","type":"GENERIC","created_at":"\#(at(136))","content":"tool output 2"}"#,
            // 最后一条没有后续步骤，不参与计算
            #"{"step_index":7,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\#(at(138))","model":"gemini-4-neon-medium","output_tokens":400,"content":"done"}"#,
        ], to: "conv-rate/.system_generated/logs/transcript.jsonl", under: antigravityRoot)

        let s = try XCTUnwrap(scanner().scan(live: [], claudeCwdCounts: [:]).first)
        // (300 + 500) tokens / (5s + 10s) = 53.333 tok/s
        XCTAssertEqual(try XCTUnwrap(s.tokensPerSecond), 800.0 / 15.0, accuracy: 0.001)
    }

    func testGeminiSessionReparsedOnlyWhenFileChanges() throws {
        let mtime = Date().addingTimeInterval(-60)
        try write([#"{"sessionId":"s","messages":[{"type":"gemini","content":"第一版"}]}"#],
                  to: "p/chats/session-1.json", under: geminiRoot, mtime: mtime)
        let s = scanner()
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.snippet, "第一版")
        // 大小与 mtime 都不变：复用缓存
        try write([#"{"sessionId":"s","messages":[{"type":"gemini","content":"第二版"}]}"#],
                  to: "p/chats/session-1.json", under: geminiRoot, mtime: mtime)
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.snippet, "第一版")
        try write([#"{"sessionId":"s","messages":[{"type":"gemini","content":"第三版内容"}]}"#],
                  to: "p/chats/session-1.json", under: geminiRoot)
        XCTAssertEqual(s.scan(live: [], claudeCwdCounts: [:]).first?.snippet, "第三版内容")
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
