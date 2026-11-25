import CryptoKit
import Foundation

// 移植自 agent-notch：通过 ps/lsof 发现终端里运行的 Claude Code / Codex 进程，
// 再扫描 ~/.claude、~/.codex 的 transcript 构建会话树。存活来自操作系统进程
// 状态，绝不来自文件 mtime。

// MARK: - 模型

enum AgentKind: String { case claude = "Claude Code", codex = "Codex", gemini = "Gemini CLI" }

private func sanitizedClaudeProjectPath(_ path: String) -> String {
    path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
}

/// 展开会话时滚动区里的一行。transcript 里没有 token 级流式数据 —— 两家都是
/// 整条消息写完才追加一行 —— 所以「实时」的颗粒度就是这里的一条。
struct TranscriptEntry: Identifiable {
    enum Role { case user, assistant, tool }
    let id: String
    let role: Role
    /// 工具行的工具名；对话行为空
    let title: String
    let text: String
}

struct AgentSession: Identifiable {
    let id: String
    let kind: AgentKind
    let title: String
    let snippet: String
    let model: String
    let lastModified: Date
    var prompt: String = ""
    // 展开会话时滚动显示的最近若干条正文与工具活动，按时间正序
    var transcript: [TranscriptEntry] = []
    var threadID: String = ""
    var parentID: String?
    var nickname: String?
    var children: [AgentSession] = []
    var isLive: Bool = false  // 进程存活（来自 discovery，绝非 mtime）
    // 最后一条 user/assistant 条目 —— away_summary 等系统写入会更新 mtime，
    // 但不能算作活动
    var lastActivity: Date?
    // 最近几次模型响应的输出速率；transcript 里拿不到可靠 usage 时为 nil
    var tokensPerSecond: Double?
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
    // Gemini CLI 同样写完即关，回退到 cwd；Antigravity（`agy`）既不持有
    // transcript fd，transcript 里也没有结构化的工作目录，只能按进程数判活。
    struct Snapshot {
        let kind: AgentKind
        let transcriptPath: String?
        let cwd: String?
        var antigravity = false
    }

    // 高负载下 Process 启动开销可能超过短超时导致所有 agent 误判为死亡，
    // 因此用宽松的预算，且每次 poll 只跑一次批量 lsof。
    private static let psTimeout: TimeInterval = 2.0
    private static let lsofTimeout: TimeInterval = 2.0

    func liveTranscripts() -> [Snapshot] {
        guard let psOut = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="], timeout: Self.psTimeout) else { return [] }
        var candidates: [(pid: String, tty: String, kind: AgentKind, antigravity: Bool)] = []
        for line in psOut.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4 else { continue }
            let pid = String(parts[0]), tty = String(parts[2])
            let command = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tty != "??", !command.isEmpty else { continue }  // 必须挂在终端上
            if isClaude(command) { candidates.append((pid, tty, .claude, false)) }
            else if isCodex(command) { candidates.append((pid, tty, .codex, false)) }
            else if isAntigravity(command) { candidates.append((pid, tty, .gemini, true)) }
            else if isGemini(command) { candidates.append((pid, tty, .gemini, false)) }
        }
        let chunks = lsofChunks(pids: candidates.map(\.pid))
        var out: [Snapshot] = []
        var claimed = Set<String>()
        for (pid, tty, kind, antigravity) in candidates {
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
            case .gemini where antigravity:
                guard claimed.insert("agy:\(tty)").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: nil, cwd: cwd, antigravity: true))
            case .gemini:
                let path = bestGeminiTranscript(in: lsof)
                guard path != nil || cwd != nil else { continue }
                guard claimed.insert("gemini:\(path ?? tty)").inserted else { continue }
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

    private func isAntigravity(_ command: String) -> Bool {
        guard let first = command.lowercased().split(separator: " ").first else { return false }
        return first == "agy" || first.hasSuffix("/agy")
    }

    private func isGemini(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("@google/gemini-cli") || lowered.contains("/gemini.js") { return true }
        return lowered.split(separator: " ").contains { token in
            token == "gemini" || token.hasSuffix("/gemini")
        }
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

    private func bestGeminiTranscript(in lsof: String) -> String? {
        lsof.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.first == "n" else { return nil }
            let v = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.contains("/.gemini/tmp/"), v.contains("/chats/session-"),
                  v.hasSuffix(".json") || v.hasSuffix(".jsonl") else { return nil }
            return v
        }.max {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                < URL(fileURLWithPath: $1).deletingPathExtension().lastPathComponent
        }
    }

    /// 超时收割队列：只发信号，永不阻塞，因此一条串行队列足够。
    private static let reaper = DispatchQueue(label: "ai.elink.proc-reaper")

    /// 只在调用方自己的线程上阻塞，绝不把等待派发到全局并发队列。
    ///
    /// 旧实现把 `readDataToEndOfFile` + `waitUntilExit` 派发到
    /// `DispatchQueue.global(qos: .utility)`，超时后只 `terminate()` 就返回，
    /// 不解除那个 block，于是每超时一次就永久漏掉一个池线程。漏满 64 个软上限
    /// 后，Foundation 投递子进程退出通知同样抢不到线程，已经退出的子进程也再
    /// 等不到通知，泄漏变得不可逆，全 app 依赖全局队列的工作随之饿死 —— 表现
    /// 为菜单栏无响应而 HTTP 服务（独占串行队列）仍然正常。
    ///
    /// 超时改由只发 SIGKILL 的 timer source 兜底。SIGKILL 不可被忽略或阻塞，
    /// 子进程必死、管道必然 EOF，因此下面的阻塞读取必然返回。
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        // pid 被收割后可能立即复用，届时 SIGKILL 会打到无关进程上。
        // kill 与「已收割」标记都排在 reaper 上，靠串行队列互斥。
        let pid = p.processIdentifier
        let reaped = Reaped()
        let killer = DispatchSource.makeTimerSource(queue: Self.reaper)
        killer.schedule(deadline: .now() + timeout)
        killer.setEventHandler { if !reaped.value { kill(pid, SIGKILL) } }
        killer.resume()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        Self.reaper.sync { reaped.value = true }
        killer.cancel()

        // 超时被杀时判为失败，与旧实现返回 nil 的语义一致；
        // 正常退出即使退出码非 0 也照用输出（lsof 部分失败时常见）。
        guard p.terminationReason == .exit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 仅供 `ProcessDiscovery.run` 在 reaper 队列上串行访问。
private final class Reaped {
    var value = false
}

// MARK: - 会话扫描

final class SessionScanner {
    private let fm = FileManager.default
    private let claudeRoot: URL
    private let codexRoot: URL
    private let geminiRoot: URL
    private let antigravityRoots: [URL]
    /// 按文件缓存的 `tailInfo` 结果，键为路径，大小或 mtime 变了才重读。
    ///
    /// 每轮 poll 都要重新判活，但活跃会话之外的 transcript 大多一个字节都没动，
    /// 以前仍每 3～5 秒各读一遍 128KB 尾部并逐行 JSON 解析。结果里的
    /// activity/rate 都来自文件内容，busy 在读取时才拿它和当前时间比，所以
    /// 内容不变就可以原样复用。只在所属监视器的串行队列上访问。
    private typealias TailInfo = (snippet: String, model: String, prompt: String,
                                  transcript: [TranscriptEntry], activity: Date?, rate: Double?)
    private var tailCache: [String: (size: Int, mtime: Date, info: TailInfo)] = [:]
    /// Gemini 会话文件的解析结果，同样按大小与 mtime 复用。Gemini CLI 的 `.json`
    /// 会话是整份对话，长会话可达数 MB，不能每轮 poll 都整份重读。
    private typealias GeminiInfo = (title: String, sessionID: String, model: String,
                                    snippet: String, activity: Date?)
    private var geminiCache: [String: (size: Int, mtime: Date, info: GeminiInfo)] = [:]
    /// 本轮 scan 用到的路径；scan 结束时据此丢掉已不再扫描的文件
    private var touched = Set<String>()

    init(claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".claude/projects"),
         codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".codex/sessions"),
         geminiRoot: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".gemini/tmp"),
         antigravityRoots: [URL] = StatusService.antigravityBrainRoots) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.geminiRoot = geminiRoot
        self.antigravityRoots = antigravityRoots
    }

    /// `live` = 运行中进程持有的 transcript 路径集合；
    /// `claudeCwdCounts` = 编码项目目录 → 该 cwd 下的 claude 进程数
    /// （claude 不持有 transcript fd 时的回退）；`geminiCwdCounts` = 进程 cwd →
    /// Gemini CLI 进程数；`antigravityLive` = Antigravity 进程数。它们是判活的唯一依据。
    func scan(live: Set<String>, claudeCwdCounts: [String: Int],
              geminiCwdCounts: [String: Int] = [:], antigravityLive: Int = 0) -> [AgentSession] {
        let recent: (AgentSession) -> Bool = { $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600 }
        touched = []
        var sessions = scanClaude(live: live, cwdCounts: claudeCwdCounts).filter(recent)
            + groupCodex(scanCodex(live: live).filter(recent))
            + scanGemini(live: live, cwdCounts: geminiCwdCounts, antigravityLive: antigravityLive).filter(recent)
        tailCache = tailCache.filter { touched.contains($0.key) }
        geminiCache = geminiCache.filter { touched.contains($0.key) }
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    private func scanGemini(live: Set<String>, cwdCounts: [String: Int],
                            antigravityLive: Int) -> [AgentSession] {
        let files: [(url: URL, mtime: Date)] = (StatusService.geminiChatFiles(
            at: geminiRoot, antigravityRoots: antigravityRoots) ?? []).compactMap { f in
            guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return nil
            }
            return (f, m)
        }.sorted { $0.mtime > $1.mtime }
        // cwd 回退：Gemini CLI 的项目目录名是新版 ~/.gemini/projects.json 里登记的
        // 短名，未登记时是 cwd 的 sha256；该目录下有 N 个进程，则最新 N 个会话判活。
        // Antigravity 没有可用的工作目录，有 N 个 agy 进程就判最新 N 个 transcript。
        var liveByDir: [String: Int] = [:]
        if !cwdCounts.isEmpty {
            let names = geminiProjectNames()
            for (cwd, n) in cwdCounts { liveByDir[names[cwd] ?? Self.sha256Hex(cwd), default: 0] += n }
        }
        var agySeen = 0
        var dirSeen: [String: Int] = [:]
        var out: [AgentSession] = []
        for (file, mtime) in files {
            let antigravity = Self.isAntigravityTranscript(file)
            var isLive = live.contains(file.path)
            if antigravity {
                isLive = isLive || agySeen < antigravityLive
                agySeen += 1
            } else {
                let dir = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let idx = dirSeen[dir, default: 0]
                dirSeen[dir] = idx + 1
                isLive = isLive || idx < liveByDir[dir, default: 0]
            }
            guard isLive || Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            let info = cachedGeminiInfo(of: file, mtime: mtime, antigravity: antigravity)
            out.append(AgentSession(
                id: file.path,
                kind: .gemini,
                title: info.title,
                snippet: info.snippet,
                model: info.model,
                lastModified: mtime,
                threadID: info.sessionID,
                isLive: isLive,
                lastActivity: info.activity ?? mtime
            ))
        }
        return out
    }

    private static func geminiText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// 重放 Gemini CLI `.jsonl` 操作日志，得到当前的元数据与消息列表，规则与
    /// Gemini CLI 自己的 chatRecordingService 一致：消息行按 `id` 插入或原位覆盖，
    /// `$set.messages` 整体替换，`$patch` 改内容 / 删除 / 重排，`$rewindTo` 删掉
    /// 该条及其后（找不到就清空）。
    static func replayGeminiLog(_ records: [[String: Any]])
        -> (meta: [String: Any], messages: [[String: Any]]) {
        var meta: [String: Any] = [:]
        var ids: [String] = []
        var byID: [String: [String: Any]] = [:]
        func upsert(_ message: [String: Any]) {
            guard let id = message["id"] as? String else { return }
            if byID[id] == nil { ids.append(id) }
            byID[id] = message
        }
        func patch(_ update: [String: Any]) {
            guard let id = update["id"] as? String, var message = byID[id],
                  let content = update["content"] else { return }
            message["content"] = content
            byID[id] = message
        }
        for record in records {
            if let target = record["$rewindTo"] as? String {
                if let i = ids.firstIndex(of: target) {
                    for id in ids[i...] { byID[id] = nil }
                    ids.removeSubrange(i...)
                } else {
                    ids = []
                    byID = [:]
                }
            } else if let p = record["$patch"] as? [String: Any] {
                patch(p)
                (p["updates"] as? [[String: Any]] ?? []).forEach(patch)
                for id in p["removeIds"] as? [String] ?? [] where byID.removeValue(forKey: id) != nil {
                    ids.removeAll { $0 == id }
                }
                if let order = p["orderIds"] as? [String] {
                    var seen = Set<String>()
                    let ordered = order.filter { byID[$0] != nil && seen.insert($0).inserted }
                    ids = ids.filter { !seen.contains($0) } + ordered
                }
            } else if record["id"] is String {
                upsert(record)
            } else if let set = record["$set"] as? [String: Any] {
                if let replacement = set["messages"] as? [[String: Any]] {
                    ids = []
                    byID = [:]
                    replacement.forEach(upsert)
                }
                meta.merge(set) { $1 }
            } else if record["sessionId"] is String {
                meta.merge(record) { $1 }
                (record["messages"] as? [[String: Any]] ?? []).forEach(upsert)
            }
        }
        return (meta, ids.compactMap { byID[$0] })
    }

    /// Antigravity：brain/<id>/.system_generated/logs/transcript.jsonl
    private static func isAntigravityTranscript(_ file: URL) -> Bool {
        file.lastPathComponent == "transcript.jsonl" && file.path.contains("/.system_generated/logs/")
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// ~/.gemini/projects.json：{"projects": {"<cwd>": "<目录短名>"}}
    private func geminiProjectNames() -> [String: String] {
        let url = geminiRoot.deletingLastPathComponent().appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root["projects"] as? [String: String] ?? [:]
    }

    private func cachedGeminiInfo(of file: URL, mtime: Date, antigravity: Bool) -> GeminiInfo {
        let path = file.path
        touched.insert(path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        if let hit = geminiCache[path], hit.size == size, hit.mtime == mtime { return hit.info }
        let info = geminiInfo(of: file, antigravity: antigravity)
        geminiCache[path] = (size, mtime, info)
        return info
    }

    private func geminiInfo(of file: URL, antigravity: Bool) -> GeminiInfo {
        // Antigravity 的文件名与上两级目录都是固定的，会话 ID 是 brain 下的目录名
        var projectName = antigravity
            ? "Antigravity"
            : file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var sessionID = antigravity
            ? file.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            : file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else { return (projectName, sessionID, "", "", nil) }
        var meta: [String: Any] = [:]
        var messages: [[String: Any]] = []
        // 按扩展名分流：只有一行的 `.jsonl` 也能整份解析成对象，不能拿来判断格式
        if file.pathExtension == "json" {
            let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            meta = root
            messages = root["messages"] as? [[String: Any]] ?? []
        } else if let text = String(data: data, encoding: .utf8) {
            let records = text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            if antigravity {
                messages = records
            } else {
                (meta, messages) = Self.replayGeminiLog(records)
            }
        }
        if let sid = meta["sessionId"] as? String, !sid.isEmpty { sessionID = sid }
        if let dirs = meta["directories"] as? [String], let first = dirs.first, !first.isEmpty {
            projectName = URL(fileURLWithPath: first).lastPathComponent
        }
        var model = ""
        var lastActivity: Date?
        var snippet = ""
        for msg in messages.reversed() {
            // Antigravity 的系统注入行不是对话活动
            if msg["source"] as? String == "SYSTEM" { continue }
            if model.isEmpty, let m = msg["model"] as? String, !m.isEmpty { model = m }
            // Gemini CLI 用 timestamp，Antigravity 用 created_at
            if lastActivity == nil, let ts = (msg["timestamp"] ?? msg["created_at"]) as? String {
                lastActivity = StatusService.timestamp(ts)
            }
            // content 可能是字符串，也可能是 [{"text": ...}] 分段；"<" 开头的是
            // 注入的上下文（<session_context>、<USER_REQUEST> 等），不当摘要
            if snippet.isEmpty, let text = Self.geminiText(msg["content"]) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.hasPrefix("<") { snippet = String(trimmed.prefix(120)) }
            }
            if !model.isEmpty && lastActivity != nil && !snippet.isEmpty { break }
        }
        return (projectName, sessionID, model, snippet, lastActivity)
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
                let isLive = live.contains(f.path) || idx < liveByCwd
                // 与 scan() 的过滤条件一致：反正会被丢弃的旧文件不读内容
                if !isLive && Date().timeIntervalSince(mtime) >= 6 * 3600 { continue }
                let projName = proj.lastPathComponent.split(separator: "-").last.map(String.init) ?? proj.lastPathComponent
                let info = cachedTailInfo(of: f, mtime: mtime)
                var sess = AgentSession(id: f.path, kind: .claude, title: projName,
                                        snippet: info.snippet, model: info.model, lastModified: mtime)
                sess.prompt = info.prompt
                sess.transcript = info.transcript
                sess.lastActivity = info.activity
                sess.tokensPerSecond = info.rate
                sess.isLive = isLive
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
            let info = cachedTailInfo(of: f, mtime: mtime)
            var sess = AgentSession(id: f.path, kind: .codex, title: meta.title,
                                    snippet: info.snippet, model: info.model, lastModified: mtime)
            sess.prompt = info.prompt
            sess.transcript = info.transcript
            sess.tokensPerSecond = info.rate
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
            let info = cachedTailInfo(of: c, mtime: mtime)
            var kid = AgentSession(id: c.path, kind: .claude, title: "subagent",
                                   snippet: info.snippet, model: info.model, lastModified: mtime)
            // 这里没有昵称 —— 用它接到的任务做标签
            kid.nickname = info.prompt.isEmpty ? "subagent" : String(info.prompt.prefix(40))
            kid.transcript = info.transcript
            // 子代理共享父进程 —— 存活继承父会话，忙碌看写入
            kid.isLive = parentLive
            kid.lastActivity = info.activity
            kid.tokensPerSecond = info.rate
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

    /// 展开区最多保留的条目数。倒序扫到这个数就停，因此长 transcript 反而
    /// 比原来更早退出，128KB 窗口是上界而非每次都要读满。
    static let maxTranscriptEntries = 40

    private func cachedTailInfo(of file: URL, mtime: Date) -> TailInfo {
        let path = file.path
        touched.insert(path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        if let hit = tailCache[path], hit.size == size, hit.mtime == mtime { return hit.info }
        let info = tailInfo(of: file)
        tailCache[path] = (size, mtime, info)
        return info
    }

    /// 读 jsonl transcript 末尾：最后一段可读文本 + 模型名 + 最后一条
    /// 对话（user/assistant）条目的时间戳，以及展开区滚动用的条目列表。
    func tailInfo(of file: URL)
        -> (snippet: String, model: String, prompt: String,
            transcript: [TranscriptEntry], activity: Date?, rate: Double?) {
        let empty = ("", "", "", [TranscriptEntry](), Date?.none, Double?.none)
        guard let fh = try? FileHandle(forReadingFrom: file) else { return empty }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 131_072)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return empty }
        var snippet = "", model = "", prompt = ""
        var transcript: [TranscriptEntry] = []
        var activity: Date?
        let lines = text.split(separator: "\n")
        for line in lines.reversed() {
            if model.isEmpty, let r = line.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast(1))
                model = model.replacingOccurrences(of: "claude-", with: "")
            }
            if snippet.isEmpty || prompt.isEmpty || activity == nil
                || transcript.count < Self.maxTranscriptEntries,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if snippet.isEmpty, let s = extractText(obj) { snippet = s }
                if prompt.isEmpty, let p = extractUserPrompt(obj) { prompt = p }
                if transcript.count < Self.maxTranscriptEntries {
                    transcript.insert(contentsOf: transcriptRows(obj), at: 0)
                }
                // "system" 条目（away_summary、压缩记录等）是内部维护，不算活动
                if activity == nil, let ty = obj["type"] as? String,
                   ty == "user" || ty == "assistant",
                   let ts = obj["timestamp"] as? String {
                    activity = Self.isoParser.date(from: ts)
                }
            }
            if !snippet.isEmpty && !model.isEmpty && !prompt.isEmpty && activity != nil
                && transcript.count >= Self.maxTranscriptEntries { break }
        }
        transcript = Array(transcript.suffix(Self.maxTranscriptEntries))
        // 滚动区靠 id 定位，同一条在两次 poll 之间必须拿到同一个 id
        transcript = transcript.enumerated().map { i, e in
            TranscriptEntry(id: "\(i)|\(e.role)|\(e.title)|\(e.text.prefix(24))",
                            role: e.role, title: e.title, text: e.text)
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
        return (snippet, model, prompt, transcript, activity, outputRate(lines))
    }

    /// 参与速率计算的最近响应数。
    static let rateSamples = 10

    /// 最近几次模型响应的输出速率（output tokens / 秒），按 token 数加权。
    /// transcript 没有逐 token 的时间，只能拿「响应前最后一条输入（用户消息或
    /// 工具结果）→ 响应最后一块落盘」当耗时，因此包含首 token 延迟 —— 这正是
    /// 用户感受到的快慢。
    func outputRate(_ lines: [Substring]) -> Double? {
        var samples: [(tokens: Int, seconds: TimeInterval)] = []
        var lastInput: Date?
        // Claude：一条 message 按内容块拆成多行，且边流式输出边执行工具时
        // tool_result 会插在块之间，所以按 message.id 聚合，遇到 user 行不能断开
        var claude: [String: (start: Date?, end: Date, tokens: Int, final: Bool)] = [:]
        var claudeOrder: [String] = []
        // Codex：一次响应以 token_usage_record 收尾；起点取它第一条输出之前的
        // 最后一条输入，响应中途回填的工具结果不算
        var codexStart: Date?, inCodexResponse = false
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // ISO 解析不便宜，只给用得上的行做
            func time() -> Date? { (obj["timestamp"] as? String).flatMap(Self.isoParser.date(from:)) }
            let type = obj["type"] as? String
            if let payload = obj["payload"] as? [String: Any] {
                let ptype = payload["type"] as? String ?? ""
                if type == "token_usage_record" {
                    if inCodexResponse, let start = codexStart, let ts = time(),
                       let out = (payload["usage"] as? [String: Any])?["output_tokens"] as? Int {
                        samples.append((out, ts.timeIntervalSince(start)))
                    }
                    codexStart = nil
                    inCodexResponse = false
                } else if type == "response_item" {
                    if ptype.hasSuffix("_output")
                        || (ptype == "message" && payload["role"] as? String != "assistant") {
                        lastInput = time()
                    } else if !inCodexResponse {
                        inCodexResponse = true
                        codexStart = lastInput
                    }
                }
                continue
            }
            if type == "user" {
                lastInput = time()
            } else if type == "assistant", let msg = obj["message"] as? [String: Any],
                      let id = msg["id"] as? String,
                      msg["model"] as? String != "<synthetic>", let ts = time() {
                let out = (msg["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
                // 旧版 Claude Code 记下的是流式中途的 usage（stop_reason 为 null，
                // output_tokens 只有个位数），只有带 stop_reason 的才是最终值
                let final = msg["stop_reason"] is String
                if var m = claude[id] {
                    m.end = ts
                    m.tokens = max(m.tokens, out)
                    m.final = m.final || final
                    claude[id] = m
                } else {
                    claude[id] = (lastInput, ts, out, final)
                    claudeOrder.append(id)
                }
            }
        }
        for id in claudeOrder {
            guard let m = claude[id], m.final, let start = m.start else { continue }
            samples.append((m.tokens, m.end.timeIntervalSince(start)))
        }
        let recent = samples.filter { $0.seconds > 0 }.suffix(Self.rateSamples)
        let tokens = recent.reduce(0) { $0 + $1.tokens }
        let seconds = recent.reduce(0) { $0 + $1.seconds }
        return tokens > 0 ? Double(tokens) / seconds : nil
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

    /// 把一行 transcript 展开成滚动区里的若干行。一条 Claude assistant 条目
    /// 可以同时含文本块和工具块，因此返回数组而不是单条。
    /// id 留空，由 `tailInfo` 定位完最终顺序后统一编号。
    private func transcriptRows(_ obj: [String: Any]) -> [TranscriptEntry] {
        func row(_ role: TranscriptEntry.Role, _ title: String, _ text: String) -> TranscriptEntry {
            TranscriptEntry(id: "", role: role, title: title, text: text)
        }
        // Codex 事件流
        if let payload = obj["payload"] as? [String: Any],
           let kind = payload["type"] as? String {
            switch kind {
            case "user_message":
                if let m = payload["message"] as? String, let t = cleanLong(m) {
                    return [row(.user, "", t)]
                }
            case "agent_message":
                if let m = payload["message"] as? String, let t = cleanLong(m) {
                    return [row(.assistant, "", t)]
                }
            case "custom_tool_call", "function_call":
                // exec 的 input 是一段 JS，arguments 是 JSON；两者都只取开头当摘要
                let name = (payload["name"] as? String) ?? "tool"
                let raw = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
                return [row(.tool, name, oneLine(raw))]
            default:
                return []
            }
            return []
        }
        // Claude 条目
        guard let ty = obj["type"] as? String, let msg = obj["message"] as? [String: Any] else {
            return []
        }
        if ty == "user" {
            if let c = msg["content"] as? String, let t = cleanLong(c) { return [row(.user, "", t)] }
            // tool_result 是工具回填给模型的，不是用户说的话
            if let arr = msg["content"] as? [[String: Any]] {
                return arr.compactMap { part in
                    guard part["type"] as? String == "text",
                          let s = part["text"] as? String, let t = cleanLong(s) else { return nil }
                    return row(.user, "", t)
                }
            }
            return []
        }
        guard ty == "assistant" else { return [] }
        if let c = msg["content"] as? String, let t = cleanLong(c) { return [row(.assistant, "", t)] }
        guard let arr = msg["content"] as? [[String: Any]] else { return [] }
        // thinking 块不进滚动区：它是内部推理，且长到会淹没真正的输出
        return arr.compactMap { part in
            switch part["type"] as? String {
            case "text":
                guard let s = part["text"] as? String, let t = cleanLong(s) else { return nil }
                return row(.assistant, "", t)
            case "tool_use":
                let name = (part["name"] as? String) ?? "tool"
                return row(.tool, name, toolSummary(part["input"] as? [String: Any] ?? [:]))
            default:
                return nil
            }
        }
    }

    /// 工具行只有一行宽度，挑参数里最有信息量的那个。未知工具退回第一个字符串参数，
    /// 这样新增工具不会显示成空白行。
    private func toolSummary(_ input: [String: Any]) -> String {
        if let p = input["file_path"] as? String, !p.isEmpty {
            return (p as NSString).lastPathComponent
        }
        for key in ["description", "pattern", "command", "path", "query", "url", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty { return oneLine(v) }
        }
        for key in input.keys.sorted() {
            if let v = input[key] as? String, !v.isEmpty { return oneLine(v) }
        }
        return ""
    }

    private func oneLine(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 100 { t = String(t.prefix(100)) + "…" }
        return t
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

    /// 与 `clean` 同样跳过 system-reminder 与工具 JSON，但保留换行、放宽长度：
    /// 展开视图是用来读正文的，压成 90 字符单行就等于没展开。
    private func cleanLong(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("{") { return nil }
        if t.count > 600 { t = String(t.prefix(600)) + "…" }
        return t
    }
}

// MARK: - 存活跟踪

/// "连续 2 次 poll 未见即移除"规则：单次 ps/lsof 抖动（超时、被安全软件
/// 拦截）不应让所有会话瞬间读作已结束。
struct LivenessTracker {
    struct Result {
        var live = Set<String>()
        var claudeCwdCounts: [String: Int] = [:]
        /// 进程 cwd（原样）→ 该目录下未持有 transcript fd 的 Gemini CLI 进程数
        var geminiCwdCounts: [String: Int] = [:]
        /// 运行中的 Antigravity（`agy`）进程数
        var antigravityCount = 0
    }

    private(set) var missCounts: [String: Int] = [:]

    /// 键为 transcript 路径，或 cwd 回退的 "cwd#<encoded>#<i>"（claude）/
    /// "gcwd#<cwd>#<i>"（Gemini CLI），或 "agy#<i>"（Antigravity）。
    mutating func update(snapshots: [ProcessDiscovery.Snapshot]) -> Result {
        var seen = Set<String>()
        var cwdIndex: [String: Int] = [:]
        var agyIndex = 0
        for snap in snapshots {
            if let path = snap.transcriptPath {
                seen.insert(path)
            } else if snap.antigravity {
                seen.insert("agy#\(agyIndex)")
                agyIndex += 1
            } else if let cwd = snap.cwd, snap.kind == .claude || snap.kind == .gemini {
                let key = snap.kind == .claude ? "cwd#\(sanitizedClaudeProjectPath(cwd))" : "gcwd#\(cwd)"
                let i = cwdIndex[key, default: 0]
                cwdIndex[key] = i + 1
                seen.insert("\(key)#\(i)")
            }
        }
        for p in seen { missCounts[p] = 0 }
        for (p, n) in missCounts where !seen.contains(p) {
            if n + 1 >= 2 { missCounts.removeValue(forKey: p) } else { missCounts[p] = n + 1 }
        }
        var result = Result()
        for key in missCounts.keys {
            if key.hasPrefix("cwd#") {
                let encoded = String(key.dropFirst(4).split(separator: "#")[0])
                result.claudeCwdCounts[encoded, default: 0] += 1
            } else if key.hasPrefix("gcwd#"), let sep = key.lastIndex(of: "#") {
                // cwd 可能含 "#"，只切掉末尾的序号
                let cwd = String(key[key.index(key.startIndex, offsetBy: 5)..<sep])
                result.geminiCwdCounts[cwd, default: 0] += 1
            } else if key.hasPrefix("agy#") {
                result.antigravityCount += 1
            } else {
                result.live.insert(key)
            }
        }
        return result
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
            let tracked = self.tracker.update(snapshots: self.discovery.liveTranscripts())
            let sessions = self.scanner.scan(live: tracked.live,
                                             claudeCwdCounts: tracked.claudeCwdCounts,
                                             geminiCwdCounts: tracked.geminiCwdCounts,
                                             antigravityLive: tracked.antigravityCount)
            DispatchQueue.main.async { completion(sessions) }
        }
    }

    /// 面板关闭时调用，避免重开时用陈旧的 miss 计数闪现过期存活状态。
    func reset() {
        queue.async { [weak self] in self?.tracker.reset() }
    }
}
