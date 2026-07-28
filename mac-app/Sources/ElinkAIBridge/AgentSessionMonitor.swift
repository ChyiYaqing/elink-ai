import Foundation

// 移植自 agent-notch：通过 ps/lsof 发现终端里运行的 Claude Code / Codex 进程，
// 再扫描 ~/.claude、~/.codex 的 transcript 构建会话树。存活来自操作系统进程
// 状态，绝不来自文件 mtime。

// MARK: - 模型

enum AgentKind: String { case claude = "Claude Code", codex = "Codex" }

private func sanitizedClaudeProjectPath(_ path: String) -> String {
    path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
}

struct AgentSession: Identifiable {
    let id: String
    let kind: AgentKind
    let title: String
    let snippet: String
    let model: String
    let lastModified: Date
    var prompt: String = ""
    var threadID: String = ""
    var parentID: String?
    var nickname: String?
    var children: [AgentSession] = []
    var isLive: Bool = false  // 进程存活（来自 discovery，绝非 mtime）
    // 最后一条 user/assistant 条目 —— away_summary 等系统写入会更新 mtime，
    // 但不能算作活动
    var lastActivity: Date?
    // 混合判定：busy = 进程存活且正在对话；存活但安静视为空闲而非完成
    var isBusy: Bool { isLive && Date().timeIntervalSince(lastActivity ?? lastModified) < 30 }
    var anyLive: Bool { isLive || children.contains { $0.isLive } }
    var anyBusy: Bool { isBusy || children.contains { $0.isBusy } }
    var effectiveLastModified: Date { children.reduce(lastModified) { max($0, $1.lastModified) } }
}

// MARK: - 进程发现

final class ProcessDiscovery {
    // Claude Code 写完即关 transcript，lsof 通常看不到打开的 jsonl，
    // 回退到进程 cwd；Codex 持有 rollout 文件的 fd，路径路由始终可用。
    struct Snapshot { let kind: AgentKind; let transcriptPath: String?; let cwd: String? }

    // 高负载下 Process 启动开销可能超过短超时导致所有 agent 误判为死亡，
    // 因此用宽松的预算，且每次 poll 只跑一次批量 lsof。
    private static let psTimeout: TimeInterval = 2.0
    private static let lsofTimeout: TimeInterval = 2.0

    func liveTranscripts() -> [Snapshot] {
        guard let psOut = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="], timeout: Self.psTimeout) else { return [] }
        var candidates: [(pid: String, tty: String, kind: AgentKind)] = []
        for line in psOut.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4 else { continue }
            let pid = String(parts[0]), tty = String(parts[2])
            let command = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tty != "??", !command.isEmpty else { continue }  // 必须挂在终端上
            if isClaude(command) { candidates.append((pid, tty, .claude)) }
            else if isCodex(command) { candidates.append((pid, tty, .codex)) }
        }
        let chunks = lsofChunks(pids: candidates.map(\.pid))
        var out: [Snapshot] = []
        var claimed = Set<String>()
        for (pid, tty, kind) in candidates {
            guard let lsof = chunks[pid] else { continue }
            let cwd = workingDirectory(from: lsof)
            // Claude 子代理运行在 .claude/worktrees/agent-*/ —— 它们是父会话
            // 的元数据，不是独立会话
            if kind == .claude, let cwd, cwd.contains("/.claude/worktrees/agent-") { continue }
            switch kind {
            case .claude:
                let path = bestClaudeTranscript(in: lsof, cwd: cwd)
                guard path != nil || cwd != nil else { continue }
                // claim key：sessionID ?? tty —— 一个终端对应一个会话
                guard claimed.insert("claude:\(path ?? tty)").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: path, cwd: cwd))
            case .codex:
                guard let path = bestCodexTranscript(in: lsof),
                      claimed.insert("codex:\(path)").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: path, cwd: cwd))
            }
        }
        return out
    }

    /// 所有 pid 一次 lsof；-Fn 输出按 `p<pid>` 标记切分。
    /// -n -P 禁用主机/端口名解析：否则持有网络 socket 的 agent 会让 lsof
    /// 卡在反向 DNS 上超时，整个 poll 误判为全部死亡。
    private func lsofChunks(pids: [String]) -> [String: String] {
        guard !pids.isEmpty,
              let outText = run("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", pids.joined(separator: ","), "-Fn"], timeout: Self.lsofTimeout) else { return [:] }
        var chunks: [String: String] = [:]
        var curPid: String?
        var cur = ""
        for line in outText.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                if let p = curPid { chunks[p] = cur }
                curPid = String(line.dropFirst())
                cur = ""
            } else {
                cur += line + "\n"
            }
        }
        if let p = curPid { chunks[p] = cur }
        return chunks
    }

    private func isClaude(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("/.local/bin/claude") { return true }
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "claude" || first.hasSuffix("/claude")
    }

    private func isCodex(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "codex" || first.hasSuffix("/codex") || lowered.contains("/codex/codex")
    }

    private func workingDirectory(from lsof: String) -> String? {
        let lines = lsof.split(whereSeparator: \.isNewline).map(String.init)
        for i in lines.indices where lines[i] == "fcwd" && lines.indices.contains(i + 1) {
            let next = lines[i + 1]
            guard next.first == "n" else { continue }
            let v = String(next.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("/") { return v }
        }
        return nil
    }

    private func paths(in lsof: String, containing fragment: String) -> [String] {
        lsof.split(whereSeparator: \.isNewline).compactMap {
            guard $0.first == "n" else { return nil }
            let v = String($0.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.contains(fragment) && v.hasSuffix(".jsonl") ? v : nil
        }
    }

    private func bestClaudeTranscript(in lsof: String, cwd: String?) -> String? {
        let all = paths(in: lsof, containing: "/.claude/projects/")
        // 一个 claude 进程可能打开多个项目 transcript；优先取编码后
        // 项目目录与进程 cwd 匹配的那个
        if all.count > 1, let cwd {
            let encoded = sanitizedClaudeProjectPath(cwd)
            if let preferred = all.first(where: { $0.contains(encoded) }) { return preferred }
        }
        return all.first
    }

    private func bestCodexTranscript(in lsof: String) -> String? {
        // rollout 文件名内嵌时间戳，名称最大即最新
        paths(in: lsof, containing: "/.codex/sessions/").max {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                < URL(fileURLWithPath: $1).deletingPathExtension().lastPathComponent
        }
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeout) == .success else { p.terminate(); return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 会话扫描

final class SessionScanner {
    private let fm = FileManager.default
    private let claudeRoot: URL
    private let codexRoot: URL

    init(claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".claude/projects"),
         codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".codex/sessions")) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }

    /// `live` = 运行中进程持有的 transcript 路径集合；
    /// `claudeCwdCounts` = 编码项目目录 → 该 cwd 下的 claude 进程数
    /// （claude 不持有 transcript fd 时的回退）。两者是判活的唯一依据。
    func scan(live: Set<String>, claudeCwdCounts: [String: Int]) -> [AgentSession] {
        let recent: (AgentSession) -> Bool = { $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600 }
        var sessions = scanClaude(live: live, cwdCounts: claudeCwdCounts).filter(recent)
            + groupCodex(scanCodex(live: live).filter(recent))
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    /// 把 Codex 子代理 rollout 折叠为根线程的 children。
    private func groupCodex(_ nodes: [AgentSession]) -> [AgentSession] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.threadID, $0) })
        func rootKey(_ n: AgentSession) -> String {
            var cur = n, hops = 0
            while let p = cur.parentID, hops < 10 {
                guard let parent = byID[p] else { return p }  // 父已过期：仍按其 id 分组
                cur = parent; hops += 1
            }
            return cur.threadID
        }
        var groups: [String: [AgentSession]] = [:]
        for n in nodes { groups[rootKey(n), default: []].append(n) }
        var out: [AgentSession] = []
        for (key, members) in groups {
            var parent = byID[key] ?? members.sorted { $0.lastModified > $1.lastModified }[0]
            var kids = members.filter { $0.threadID != parent.threadID }
            kids.sort { $0.lastModified > $1.lastModified }
            // 一个 codex 进程服务整个线程组，但只持有最近打开的 rollout fd ——
            // 组内任一成员判活即整组存活
            if parent.isLive || kids.contains(where: { $0.isLive }) {
                parent.isLive = true
                for i in kids.indices { kids[i].isLive = true }
            }
            parent.children = kids
            out.append(parent)
        }
        return out
    }

    private func scanClaude(live: Set<String>, cwdCounts: [String: Int]) -> [AgentSession] {
        var out: [AgentSession] = []
        guard let projects = try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil) else { return out }
        for proj in projects {
            guard let files = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            var dated: [(URL, Date)] = files.compactMap { f in
                guard f.pathExtension == "jsonl",
                      let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (f, m)
            }
            dated.sort { $0.1 > $1.1 }
            // cwd 回退：该项目目录下有 N 个 claude 进程，则最新 N 个 transcript
            // 判活（claude 不持有 transcript fd）
            let liveByCwd = cwdCounts[proj.lastPathComponent] ?? 0
            for (idx, (f, mtime)) in dated.enumerated() {
                let projName = proj.lastPathComponent.split(separator: "-").last.map(String.init) ?? proj.lastPathComponent
                let info = tailInfo(of: f)
                var sess = AgentSession(id: f.path, kind: .claude, title: projName,
                                        snippet: info.snippet, model: info.model, lastModified: mtime)
                sess.prompt = info.prompt
                sess.lastActivity = info.activity
                sess.isLive = live.contains(f.path) || idx < liveByCwd
                sess.children = claudeSubagents(sessionFile: f, parentLive: sess.isLive)
                out.append(sess)
            }
        }
        return out
    }

    private func scanCodex(live: Set<String>) -> [AgentSession] {
        var out: [AgentSession] = []
        guard let en = fm.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            // 旧文件提前跳过，避免读内容
            if Date().timeIntervalSince(mtime) > 6 * 3600 { continue }
            let meta = codexMeta(of: f)
            let info = tailInfo(of: f)
            var sess = AgentSession(id: f.path, kind: .codex, title: meta.title,
                                    snippet: info.snippet, model: info.model, lastModified: mtime)
            sess.prompt = info.prompt
            sess.isLive = live.contains(f.path)
            sess.threadID = meta.id
            sess.parentID = meta.parentID
            sess.nickname = meta.nickname
            out.append(sess)
        }
        return out
    }

    /// Claude Code 子代理 transcript 位于 <proj>/<session-uuid>/subagents/agent-*.jsonl
    private func claudeSubagents(sessionFile f: URL, parentLive: Bool) -> [AgentSession] {
        let dir = f.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var kids: [AgentSession] = []
        for c in files where c.pathExtension == "jsonl" {
            guard let mtime = (try? c.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            let info = tailInfo(of: c)
            var kid = AgentSession(id: c.path, kind: .claude, title: "subagent",
                                   snippet: info.snippet, model: info.model, lastModified: mtime)
            // 这里没有昵称 —— 用它接到的任务做标签
            kid.nickname = info.prompt.isEmpty ? "subagent" : String(info.prompt.prefix(40))
            // 子代理共享父进程 —— 存活继承父会话，忙碌看写入
            kid.isLive = parentLive
            kid.lastActivity = info.activity
            kids.append(kid)
        }
        return kids.sorted { $0.lastModified > $1.lastModified }
    }

    private func codexMeta(of file: URL) -> (title: String, id: String, parentID: String?, nickname: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return ("Codex", file.path, nil, nil) }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 262_144)
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return ("Codex", file.path, nil, nil) }
        let title = ((payload["cwd"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "Codex"
        let id = (payload["id"] as? String) ?? file.path
        let parentID = payload["parent_thread_id"] as? String
        let nickname = (((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["agent_nickname"] as? String
        return (title, id, parentID, nickname)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 读 jsonl transcript 末尾：最后一段可读文本 + 模型名 + 最后一条
    /// 对话（user/assistant）条目的时间戳。
    func tailInfo(of file: URL) -> (snippet: String, model: String, prompt: String, activity: Date?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return ("", "", "", nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 131_072)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return ("", "", "", nil) }
        var snippet = "", model = "", prompt = ""
        var activity: Date?
        for line in text.split(separator: "\n").reversed() {
            if model.isEmpty, let r = line.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast(1))
                model = model.replacingOccurrences(of: "claude-", with: "")
            }
            if snippet.isEmpty || prompt.isEmpty || activity == nil,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if snippet.isEmpty, let s = extractText(obj) { snippet = s }
                if prompt.isEmpty, let p = extractUserPrompt(obj) { prompt = p }
                // "system" 条目（away_summary、压缩记录等）是内部维护，不算活动
                if activity == nil, let ty = obj["type"] as? String,
                   ty == "user" || ty == "assistant",
                   let ts = obj["timestamp"] as? String {
                    activity = Self.isoParser.date(from: ts)
                }
            }
            if !snippet.isEmpty && !model.isEmpty && !prompt.isEmpty && activity != nil { break }
        }
        if model.isEmpty, size > readLen {
            // 长 transcript 里模型名可能只出现在开头 —— 补查文件头
            try? fh.seek(toOffset: 0)
            if let head = try? fh.read(upToCount: 65_536),
               let headText = String(data: head, encoding: .utf8),
               let r = headText.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(headText[r].dropFirst(9).dropLast(1))
                    .replacingOccurrences(of: "claude-", with: "")
            }
        }
        return (snippet, model, prompt, activity)
    }

    /// 若该行是用户消息则提取。
    private func extractUserPrompt(_ obj: [String: Any]) -> String? {
        // Codex: {"payload":{"type":"user_message","message":"..."}}
        if let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "user_message",
           let m = payload["message"] as? String { return clean(m) }
        // Claude: {"type":"user","message":{"content":"..." | [{"type":"text","text":...}]}}
        if obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] {
            if let c = msg["content"] as? String { return clean(c) }
            if let arr = msg["content"] as? [[String: Any]] {
                for part in arr where part["type"] as? String == "text" {
                    if let t = part["text"] as? String { return clean(t) }
                }
            }
        }
        return nil
    }

    private func extractText(_ obj: [String: Any]) -> String? {
        // Claude: {"message": {"content": [{"type":"text","text":...}] | "..."}}
        var content: Any? = nil
        if let msg = obj["message"] as? [String: Any] { content = msg["content"] }
        // Codex: {"payload": {"content": [...]}} 或嵌套 message
        if content == nil, let payload = obj["payload"] as? [String: Any] {
            content = payload["content"] ?? (payload["message"] as? [String: Any])?["content"]
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr.reversed() {
                if let t = part["text"] as? String { return clean(t) }
            }
        }
        return nil
    }

    private func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("{") { return nil }  // 跳过 system-reminder / 工具 json
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 90 { t = String(t.prefix(90)) + "…" }
        return t
    }
}

// MARK: - 存活跟踪

/// "连续 2 次 poll 未见即移除"规则：单次 ps/lsof 抖动（超时、被安全软件
/// 拦截）不应让所有会话瞬间读作已结束。
struct LivenessTracker {
    private(set) var missCounts: [String: Int] = [:]

    /// 键为 transcript 路径，或 claude cwd 回退的 "cwd#<encoded>#<i>"。
    mutating func update(snapshots: [ProcessDiscovery.Snapshot])
        -> (live: Set<String>, claudeCwdCounts: [String: Int]) {
        var seen = Set<String>()
        var cwdIndex: [String: Int] = [:]
        for snap in snapshots {
            if let path = snap.transcriptPath {
                seen.insert(path)
            } else if snap.kind == .claude, let cwd = snap.cwd {
                let encoded = sanitizedClaudeProjectPath(cwd)
                let i = cwdIndex[encoded, default: 0]
                cwdIndex[encoded] = i + 1
                seen.insert("cwd#\(encoded)#\(i)")
            }
        }
        for p in seen { missCounts[p] = 0 }
        for (p, n) in missCounts where !seen.contains(p) {
            if n + 1 >= 2 { missCounts.removeValue(forKey: p) } else { missCounts[p] = n + 1 }
        }
        var live = Set<String>()
        var cwdCounts: [String: Int] = [:]
        for key in missCounts.keys {
            if key.hasPrefix("cwd#") {
                let encoded = String(key.dropFirst(4).split(separator: "#")[0])
                cwdCounts[encoded, default: 0] += 1
            } else {
                live.insert(key)
            }
        }
        return (live, cwdCounts)
    }

    mutating func reset() { missCounts = [:] }
}

// MARK: - 监视器

final class AgentSessionMonitor {
    private static let enabledKey = "elink_agent_sessions_enabled"

    static var isEnabled: Bool {
        get { enabled(in: .standard) }
        set { setEnabled(newValue, in: .standard) }
    }

    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }

    private let discovery = ProcessDiscovery()
    private let scanner = SessionScanner()
    private var tracker = LivenessTracker()
    private let queue = DispatchQueue(label: "ai.elink.agent-sessions", qos: .utility)

    func poll(completion: @escaping ([AgentSession]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let (live, cwdCounts) = self.tracker.update(snapshots: self.discovery.liveTranscripts())
            let sessions = self.scanner.scan(live: live, claudeCwdCounts: cwdCounts)
            DispatchQueue.main.async { completion(sessions) }
        }
    }

    /// 面板关闭时调用，避免重开时用陈旧的 miss 计数闪现过期存活状态。
    func reset() {
        queue.async { [weak self] in self?.tracker.reset() }
    }
}
