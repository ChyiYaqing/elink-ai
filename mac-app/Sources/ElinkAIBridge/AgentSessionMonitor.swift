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

/// 单会话轻量实时监控摘要（随每 3 秒轮询缓存计算，不常驻全量步骤数组）。
struct SessionMetrics: Equatable {
    /// 最新一次模型调用的上下文长度（含输入 + 缓存读取 + 缓存写入）；无法可靠获取时为 nil
    var contextTokens: Int?
    /// 模型上下文窗口上限；未知模型时为 nil（UI 仅展示绝对 token 数）
    var contextWindow: Int?
    /// 缓存命中率（0...1），分母 = 非缓存输入 + 缓存读取 + 缓存写入
    var cacheHitRate: Double?
    /// 按官方 API 单价折算的等价成本（美元）；无定价模型或无用量时为 nil
    var sessionCost: Double?
    /// 统计窗口内的累计总 token
    var totalTokens: Int = 0
    /// 是否来自长日志的尾部采样窗口（>128 KiB 时列表只扫尾部，需与详情全量口径区分）
    var isPartialWindow: Bool = false

    var contextRatio: Double? {
        guard let ctx = contextTokens, let limit = contextWindow, limit > 0, ctx <= limit else {
            return nil
        }
        return Double(ctx) / Double(limit)
    }
}

enum StepAnomaly: String, Hashable {
    case lowCache
    case slowResponse
    case compaction

    var label: String {
        switch self {
        case .lowCache: return tr("低缓存", "Low Cache")
        case .slowResponse: return tr("慢响应", "Slow")
        case .compaction: return tr("压缩", "Compaction")
        }
    }
}

/// 按需加载的单次模型调用步骤明细（仅在打开 SessionDetailView 时解析单文件最近 80 步）。
struct SessionStep: Identifiable, Equatable {
    let id: String
    let index: Int
    let timestamp: Date?
    let model: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    /// 该步上下文长度；Codex 缺少单步 last_token_usage 时为 nil
    let contextTokens: Int?
    let durationSeconds: TimeInterval?
    let cost: Double?
    /// 仅提供 total_tokens、缺少分类字段的 Codex 日志保留总量，不丢弃整步
    var uncategorizedTotalTokens: Int = 0
    var anomalies: [StepAnomaly] = []

    var totalPromptTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
    var totalGeneratedTokens: Int { outputTokens + reasoningTokens }
    var totalTokens: Int {
        let categorized = totalPromptTokens + totalGeneratedTokens
        return categorized > 0 ? categorized : uncategorizedTotalTokens
    }

    var cacheHitRate: Double? {
        guard totalPromptTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(totalPromptTokens)
    }

    var tokensPerSecond: Double? {
        guard let duration = durationSeconds, duration > 0, totalGeneratedTokens > 0 else { return nil }
        return Double(totalGeneratedTokens) / duration
    }
}

/// 打开 SessionDetailView 时按需加载的单会话完整监控快照。
struct SessionInspection: Equatable {
    var metrics: SessionMetrics
    /// 最近若干步明细，按时间倒序（最新步骤在顶部）
    var steps: [SessionStep]
    var unpricedModels: [String] = []
    var totalStepCount: Int = 0
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
    // 实时监控轻量摘要（上下文占用、缓存命中率、会话等价成本）
    var metrics: SessionMetrics = SessionMetrics()
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
        /// Gemini CLI 的会话身份：一个终端一个会话。它默认会派生一个共用
        /// 终端的 node 子进程，按 pid 算会把同一次启动算成两个。
        var tty = ""
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
            else if Self.isGemini(command) { candidates.append((pid, tty, .gemini, false)) }
        }
        let chunks = lsofChunks(pids: candidates.map(\.pid))
        var out: [Snapshot] = []
        var claimed = Set<String>()
        var geminiByTTY: [String: Snapshot] = [:]
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
                // 同一终端的启动器和子进程合并成一个，有打开的会话文件的优先
                if geminiByTTY[tty]?.transcriptPath != nil { continue }
                geminiByTTY[tty] = Snapshot(kind: kind, transcriptPath: path, cwd: cwd, tty: tty)
            }
        }
        return out + geminiByTTY.keys.sorted().compactMap { geminiByTTY[$0] }
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

    static func isGemini(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("@google/gemini-cli") || lowered.contains("/gemini.js") { return true }
        // 只认可执行文件本身，或 node 直接运行的 gemini 脚本；`vim gemini`
        // 这类恰好带 gemini 参数的进程不算
        let tokens = lowered.split(separator: " ")
        func isGeminiToken(_ token: Substring) -> Bool { token == "gemini" || token.hasSuffix("/gemini") }
        guard let first = tokens.first else { return false }
        if isGeminiToken(first) { return true }
        // node 前面可能有任意启动选项（`node --require x /opt/homebrew/bin/gemini`），
        // 不去解析选项，只要参数里有 gemini 入口就算
        guard first == "node" || first.hasSuffix("/node") else { return false }
        return tokens.dropFirst().contains(where: isGeminiToken)
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
                                  transcript: [TranscriptEntry], activity: Date?, rate: Double?,
                                  metrics: SessionMetrics)
    private var tailCache: [String: (size: Int, mtime: Date, pricing: [String: ModelPricing], info: TailInfo)] = [:]
    /// Gemini 会话文件的解析结果，同样按大小、mtime 与定价表复用。Gemini CLI 的 `.json`
    /// 会话是整份对话，长会话可达数 MB，不能每轮 poll 都整份重读。
    private typealias GeminiInfo = (title: String, sessionID: String, model: String,
                                    snippet: String, activity: Date?, rate: Double?,
                                    metrics: SessionMetrics)
    private var geminiCache: [String: (size: Int, mtime: Date, pricing: [String: ModelPricing], info: GeminiInfo)] = [:]
    /// Antigravity 纯文本回复没有独立结束时间戳：在步骤落盘于文件末尾时记下
    /// 其 `mtime`，后续用户继续对话追加 `USER_INPUT` 后仍能保留已测样本。
    /// 由 `stateLock` 保护，供后台轮询队列与独立的详情解析队列安全共享。
    private let stateLock = NSLock()
    private var antigravityStepEnds: [String: [Int: Date]] = [:]
    /// 单会话按需详情缓存（仅在打开 SessionDetailView 时写入，关闭或切换时由上层丢弃）
    private var inspectionCache: (path: String, size: Int, mtime: Date,
                                  pricing: [String: ModelPricing], value: SessionInspection)?
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
              geminiCwdCounts: [String: Int] = [:], antigravityLive: Int = 0,
              pricing: [String: ModelPricing] = Pricing.table()) -> [AgentSession] {
        let recent: (AgentSession) -> Bool = { $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600 }
        touched = []
        var sessions = scanClaude(live: live, cwdCounts: claudeCwdCounts, pricing: pricing).filter(recent)
            + groupCodex(scanCodex(live: live, pricing: pricing).filter(recent))
            + scanGemini(live: live, cwdCounts: geminiCwdCounts,
                         antigravityLive: antigravityLive, pricing: pricing).filter(recent)
        tailCache = tailCache.filter { touched.contains($0.key) }
        geminiCache = geminiCache.filter { touched.contains($0.key) }
        stateLock.lock()
        antigravityStepEnds = antigravityStepEnds.filter { touched.contains($0.key) }
        stateLock.unlock()
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    private func scanGemini(live: Set<String>, cwdCounts: [String: Int],
                            antigravityLive: Int,
                            pricing: [String: ModelPricing]) -> [AgentSession] {
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
            // 已按打开的文件精确判活的会话不占兜底名额，名额只分给未匹配的会话
            var isLive = live.contains(file.path)
            if !isLive && antigravity {
                isLive = agySeen < antigravityLive
                agySeen += 1
            } else if !isLive {
                let dir = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let idx = dirSeen[dir, default: 0]
                dirSeen[dir] = idx + 1
                isLive = idx < liveByDir[dir, default: 0]
            }
            guard isLive || Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            let info = cachedGeminiInfo(of: file, mtime: mtime, antigravity: antigravity, pricing: pricing)
            out.append(AgentSession(
                id: file.path,
                kind: .gemini,
                title: info.title,
                snippet: info.snippet,
                model: info.model,
                lastModified: mtime,
                threadID: info.sessionID,
                isLive: isLive,
                lastActivity: info.activity ?? mtime,
                tokensPerSecond: info.rate,
                metrics: info.metrics
            ))
        }
        return out
    }

    /// Antigravity 把用户输入包在 `<USER_REQUEST>` 里，取出正文；其余已知的
    /// 注入块（设置变更、系统消息、附加元数据、会话上下文）不当摘要。真实消息
    /// 以 `<div>` 等开头时照常显示。
    /// Antigravity 和 Gemini CLI（bundle 里的 `<..._context>` 等）注入消息的标签
    private static let injectedGeminiTags = [
        "<USER_SETTINGS_CHANGE>", "<SYSTEM_MESSAGE>", "<ADDITIONAL_METADATA>",
        "<session_context>", "<hook_context>", "<project_context>", "<extension_context>",
        "<global_context>", "<untrusted_context>", "<user_project_memory>", "<activated_skill>",
    ]

    static func geminiSnippetText(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = "<USER_REQUEST>"
        if trimmed.hasPrefix(request) {
            trimmed = String(trimmed.dropFirst(request.count))
            if let end = trimmed.range(of: "</USER_REQUEST>") { trimmed = String(trimmed[..<end.lowerBound]) }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if Self.injectedGeminiTags.contains(where: { trimmed.hasPrefix($0) }) {
            return nil
        }
        return trimmed.isEmpty ? nil : trimmed
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

    /// 从 Gemini CLI `.jsonl` 原始操作日志中提取所有产生过用量的消息（按 `id` 去重、
    /// 保留 `$rewindTo` / `$set.messages` 回退前已消耗的调用，与 `StatusService.geminiUsageEvents` 一致）。
    static func allGeminiUsageMessages(from records: [[String: Any]]) -> [[String: Any]] {
        var order: [String] = []
        var byID: [String: [String: Any]] = [:]
        var anonymous: [[String: Any]] = []
        for record in records {
            if record["$patch"] != nil || record["$rewindTo"] != nil { continue }
            for msg in StatusService.geminiRecordMessages(record) {
                if let id = msg["id"] as? String, !id.isEmpty {
                    if let existing = byID[id] {
                        var merged = msg
                        // 同 ID 后续替换若不带 tokens，保留已记录的有效用量（与 StatusService 口径一致）
                        if merged["tokens"] == nil, let oldTokens = existing["tokens"] {
                            merged["tokens"] = oldTokens
                        }
                        if (merged["model"] as? String ?? "").isEmpty, let oldModel = existing["model"] {
                            merged["model"] = oldModel
                        }
                        byID[id] = merged
                    } else {
                        order.append(id)
                        byID[id] = msg
                    }
                } else if msg["type"] is String {
                    anonymous.append(msg)
                }
            }
        }
        return order.compactMap { byID[$0] } + anonymous
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

    private func cachedGeminiInfo(of file: URL, mtime: Date, antigravity: Bool,
                                  pricing: [String: ModelPricing]) -> GeminiInfo {
        let path = file.path
        touched.insert(path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        if let hit = geminiCache[path], hit.size == size, hit.mtime == mtime,
           hit.pricing == pricing { return hit.info }
        let info = geminiInfo(of: file, mtime: mtime, antigravity: antigravity, pricing: pricing)
        geminiCache[path] = (size, mtime, pricing, info)
        return info
    }

    private func geminiInfo(of file: URL, mtime: Date, antigravity: Bool,
                            pricing: [String: ModelPricing]) -> GeminiInfo {
        // Antigravity 的文件名与上两级目录都是固定的，会话 ID 是 brain 下的目录名
        var projectName = antigravity
            ? "Antigravity"
            : file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var sessionID = antigravity
            ? file.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            : file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else {
            return (projectName, sessionID, "", "", nil, nil, SessionMetrics())
        }
        // 读取后核对文件版本（新建 URL 绕过 Foundation 的 resourceValues 缓存），
        // 避免 stat 之后、读取之前落盘导致旧 mtime 被误缓存为新回复的结束时间
        let afterRead = try? URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stableMtime: Date? = (afterRead?.contentModificationDate == mtime
                                  && afterRead?.fileSize == data.count) ? mtime : nil
        var meta: [String: Any] = [:]
        var messages: [[String: Any]] = []
        var usageMessages: [[String: Any]] = []
        // 按扩展名分流：只有一行的 `.jsonl` 也能整份解析成对象，不能拿来判断格式
        if file.pathExtension == "json" {
            let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            meta = root
            messages = root["messages"] as? [[String: Any]] ?? []
            usageMessages = messages
        } else if let text = String(data: data, encoding: .utf8) {
            let records = text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            if antigravity {
                messages = records
                usageMessages = records
            } else {
                (meta, messages) = Self.replayGeminiLog(records)
                usageMessages = Self.allGeminiUsageMessages(from: records)
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
            // content 可能是字符串，也可能是 [{"text": ...}] 分段
            if snippet.isEmpty, let text = Self.geminiText(msg["content"]).flatMap(Self.geminiSnippetText) {
                snippet = String(text.prefix(120))
            }
            if !model.isEmpty && lastActivity != nil && !snippet.isEmpty { break }
        }
        var observedEnds: [Int: Date] = [:]
        if antigravity {
            stateLock.lock()
            if let stableMtime, let last = messages.last,
               last["type"] as? String == "PLANNER_RESPONSE",
               (last["status"] as? String ?? "DONE") == "DONE",
               let step = (last["step_index"] as? NSNumber)?.intValue,
               antigravityStepEnds[file.path]?[step] == nil,
               let start = StatusService.timestamp(last["created_at"]) {
                let dt = stableMtime.timeIntervalSince(start)
                if dt > 0 && dt <= 600 {
                    antigravityStepEnds[file.path, default: [:]][step] = stableMtime
                }
            }
            observedEnds = antigravityStepEnds[file.path] ?? [:]
            stateLock.unlock()
        }
        // 实时指标（输出速率、当前上下文）取自重放后的当前对话分支；
        // 累计用量、缓存命中率与等价成本取自保留回退前记录的完整操作日志。
        let rate = Self.geminiOutputRate(messages, antigravity: antigravity,
                                         fileModified: stableMtime, observedEnds: observedEnds)
        let activeParsed = Self.parseGeminiSteps(messages, antigravity: antigravity,
                                                 fileModified: stableMtime, observedEnds: observedEnds,
                                                 pricing: pricing)
        let usageParsed = antigravity
            ? activeParsed
            : Self.parseGeminiSteps(usageMessages, antigravity: false,
                                    fileModified: stableMtime, observedEnds: observedEnds,
                                    pricing: pricing)
        let metrics = Self.summarizeMetrics(steps: usageParsed.steps, fallbackModel: model,
                                            explicitContextWindow: nil,
                                            currentContextOverride: activeParsed.steps.last?.contextTokens,
                                            hasCurrentContextOverride: !antigravity)
        return (projectName, sessionID, model, snippet, lastActivity, rate, metrics)
    }

    /// 计算 Gemini CLI / Antigravity 会话最近响应的输出速率（output tokens / 秒）。
    /// - Gemini CLI：`gemini` 消息的 `timestamp` 是响应完成时间，起点取前一条 `user`
    ///   消息或上一轮 `toolCalls` 的最晚完成时间；输出 token 合并 `output + thoughts`
    ///   （与 Claude/Codex 把思维链计入 `output_tokens` 的口径一致）。
    /// - Antigravity：`PLANNER_RESPONSE` 的 `created_at` 是生成起点；紧跟工具/模型
    ///   步骤时以下一条的 `created_at` 为生成终点；若处于文件末尾且已 `DONE`，
    ///   `transcript.jsonl` 是在步骤完成时落盘的，用文件 `mtime` 作终点（设 10 分钟
    ///   上限，避免文件被事后触碰导致失真），并按 `step_index` 缓存供后续轮次复用。
    static func geminiOutputRate(
        _ messages: [[String: Any]],
        antigravity: Bool,
        fileModified: Date? = nil,
        observedEnds: [Int: Date] = [:]
    ) -> Double? {
        var samples: [(tokens: Int, seconds: TimeInterval)] = []
        if antigravity {
            for i in messages.indices {
                let msg = messages[i]
                guard msg["type"] as? String == "PLANNER_RESPONSE",
                      (msg["status"] as? String ?? "DONE") == "DONE",
                      let out = (msg["output_tokens"] as? NSNumber)?.intValue, out > 0,
                      let start = StatusService.timestamp(msg["created_at"]) else { continue }
                let step = (msg["step_index"] as? NSNumber)?.intValue
                let end: Date?
                if messages.indices.contains(i + 1) {
                    let next = messages[i + 1]
                    if next["type"] as? String != "USER_INPUT",
                       next["source"] as? String != "USER_EXPLICIT",
                       next["source"] as? String != "SYSTEM" {
                        end = StatusService.timestamp(next["created_at"])
                    } else if let step {
                        end = observedEnds[step]
                    } else {
                        end = nil
                    }
                } else if let step, let recorded = observedEnds[step] {
                    end = recorded
                } else if let mtime = fileModified,
                          mtime.timeIntervalSince(start) <= 600 {
                    end = mtime
                } else {
                    end = nil
                }
                if let end {
                    let dt = end.timeIntervalSince(start)
                    if dt > 0 { samples.append((out, dt)) }
                }
            }
        } else {
            var lastInput: Date?
            for msg in messages {
                let type = msg["type"] as? String
                if type == "user" {
                    lastInput = StatusService.timestamp(msg["timestamp"])
                } else if type == "gemini" {
                    let ts = StatusService.timestamp(msg["timestamp"])
                    if let start = lastInput, let end = ts,
                       let tokens = msg["tokens"] as? [String: Any] {
                        let output = max(0, (tokens["output"] as? NSNumber)?.intValue ?? 0)
                        let thoughts = max(0, (tokens["thoughts"] as? NSNumber)?.intValue ?? 0)
                        let generated = output + thoughts
                        let dt = end.timeIntervalSince(start)
                        if generated > 0 && dt > 0 { samples.append((generated, dt)) }
                    }
                    let toolEnd = (msg["toolCalls"] as? [[String: Any]])?
                        .compactMap { StatusService.timestamp($0["timestamp"]) }
                        .max()
                    if let nextStart = toolEnd ?? ts { lastInput = nextStart }
                }
            }
        }
        let recent = samples.filter { $0.seconds > 0 }.suffix(Self.rateSamples)
        let tokens = recent.reduce(0) { $0 + $1.tokens }
        let seconds = recent.reduce(0) { $0 + $1.seconds }
        return tokens > 0 && seconds > 0 ? Double(tokens) / seconds : nil
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

    private func scanClaude(live: Set<String>, cwdCounts: [String: Int],
                            pricing: [String: ModelPricing]) -> [AgentSession] {
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
                let info = cachedTailInfo(of: f, kind: .claude, mtime: mtime, pricing: pricing)
                var sess = AgentSession(id: f.path, kind: .claude, title: projName,
                                        snippet: info.snippet, model: info.model, lastModified: mtime)
                sess.prompt = info.prompt
                sess.transcript = info.transcript
                sess.lastActivity = info.activity
                sess.tokensPerSecond = info.rate
                sess.metrics = info.metrics
                sess.isLive = isLive
                sess.children = claudeSubagents(sessionFile: f, parentLive: sess.isLive, pricing: pricing)
                out.append(sess)
            }
        }
        return out
    }

    private func scanCodex(live: Set<String>, pricing: [String: ModelPricing]) -> [AgentSession] {
        var out: [AgentSession] = []
        guard let en = fm.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            // 旧文件提前跳过，避免读内容
            if Date().timeIntervalSince(mtime) > 6 * 3600 { continue }
            let meta = codexMeta(of: f)
            let info = cachedTailInfo(of: f, kind: .codex, mtime: mtime, pricing: pricing)
            var sess = AgentSession(id: f.path, kind: .codex, title: meta.title,
                                    snippet: info.snippet, model: info.model, lastModified: mtime)
            sess.prompt = info.prompt
            sess.transcript = info.transcript
            sess.tokensPerSecond = info.rate
            sess.metrics = info.metrics
            sess.isLive = live.contains(f.path)
            sess.threadID = meta.id
            sess.parentID = meta.parentID
            sess.nickname = meta.nickname
            out.append(sess)
        }
        return out
    }

    /// Claude Code 子代理 transcript 位于 <proj>/<session-uuid>/subagents/agent-*.jsonl
    private func claudeSubagents(sessionFile f: URL, parentLive: Bool,
                                 pricing: [String: ModelPricing]) -> [AgentSession] {
        let dir = f.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var kids: [AgentSession] = []
        for c in files where c.pathExtension == "jsonl" {
            guard let mtime = (try? c.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            let info = cachedTailInfo(of: c, kind: .claude, mtime: mtime, pricing: pricing)
            var kid = AgentSession(id: c.path, kind: .claude, title: "subagent",
                                   snippet: info.snippet, model: info.model, lastModified: mtime)
            // 这里没有昵称 —— 用它接到的任务做标签
            kid.nickname = info.prompt.isEmpty ? "subagent" : String(info.prompt.prefix(40))
            kid.transcript = info.transcript
            // 子代理共享父进程 —— 存活继承父会话，忙碌看写入
            kid.isLive = parentLive
            kid.lastActivity = info.activity
            kid.tokensPerSecond = info.rate
            kid.metrics = info.metrics
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
    /// SessionDetailView 最多保留的最近步骤数，避免超长会话撑爆 UI 与内存。
    static let maxInspectionSteps = 80

    private func cachedTailInfo(of file: URL, kind: AgentKind, mtime: Date,
                                pricing: [String: ModelPricing]) -> TailInfo {
        let path = file.path
        touched.insert(path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        if let hit = tailCache[path], hit.size == size, hit.mtime == mtime,
           hit.pricing == pricing { return hit.info }
        let info = tailInfo(of: file, kind: kind, pricing: pricing)
        tailCache[path] = (size, mtime, pricing, info)
        return info
    }

    /// 读 jsonl transcript 末尾：最后一段可读文本 + 模型名 + 最后一条
    /// 对话（user/assistant）条目的时间戳，以及展开区滚动用的条目列表。
    func tailInfo(of file: URL, kind: AgentKind = .claude,
                  pricing: [String: ModelPricing] = Pricing.builtIn)
        -> (snippet: String, model: String, prompt: String,
            transcript: [TranscriptEntry], activity: Date?, rate: Double?,
            metrics: SessionMetrics) {
        let empty = ("", "", "", [TranscriptEntry](), Date?.none, Double?.none, SessionMetrics())
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
        let isPartial = size > readLen
        var metrics: SessionMetrics
        if kind == .codex {
            let parsed = Self.parseCodexSteps(lines, pricing: pricing, fallbackModel: model,
                                              isPartialTail: isPartial)
            metrics = Self.summarizeMetrics(steps: parsed.steps, fallbackModel: model,
                                            explicitContextWindow: parsed.contextWindow)
        } else {
            let parsed = Self.parseClaudeSteps(lines, pricing: pricing)
            metrics = Self.summarizeMetrics(steps: parsed.steps, fallbackModel: model,
                                            explicitContextWindow: nil)
        }
        metrics.isPartialWindow = isPartial
        return (snippet, model, prompt, transcript, activity, outputRate(lines), metrics)
    }

    // MARK: - 会话指标与按需步骤明细

    /// 仅返回明确可确认的上下文窗口上限（显式 `[1m]` 标记或已确认上限的 Gemini 系列）；
    /// 其他未知模型或变体返回 nil，UI 仅展示绝对 token 数，避免误报占用率与告警颜色。
    static func modelContextWindow(for rawModel: String) -> Int? {
        let m = rawModel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }
        if m.contains("[1m]") { return 1_000_000 }
        if m.hasPrefix("gemini-1.5-pro") { return 2_000_000 }
        if m.hasPrefix("gemini-1.5-flash")
            || m.hasPrefix("gemini-2.5-")
            || m.hasPrefix("gemini-3-")
            || m.hasPrefix("gemini-3.5-")
            || m.hasPrefix("gemini-3.8-")
            || m.hasPrefix("gemini-4-") {
            return 1_000_000
        }
        return nil
    }

    /// 按需读取单个会话文件并解析最近 80 步明细（仅在打开 SessionDetailView 时调用，
    /// 线程安全：可在独立的详情队列上执行，不阻塞后台存活轮询）。
    func inspect(session: AgentSession,
                 pricing: [String: ModelPricing] = Pricing.table()) -> SessionInspection {
        let file = URL(fileURLWithPath: session.id)
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let mtime = values?.contentModificationDate ?? session.lastModified
        stateLock.lock()
        let cachedHit = inspectionCache
        let observedEnds = antigravityStepEnds[session.id] ?? [:]
        stateLock.unlock()
        if let hit = cachedHit, hit.path == session.id, hit.size == size,
           hit.mtime == mtime, hit.pricing == pricing {
            return hit.value
        }
        let result = Self.inspectFile(file, kind: session.kind, fallbackModel: session.model,
                                      mtime: mtime,
                                      observedEnds: observedEnds,
                                      pricing: pricing)
        stateLock.lock()
        inspectionCache = (session.id, size, mtime, pricing, result)
        stateLock.unlock()
        return result
    }

    func clearInspectionCache() {
        stateLock.lock()
        inspectionCache = nil
        stateLock.unlock()
    }

    static func inspectFile(_ file: URL, kind: AgentKind, fallbackModel: String = "",
                            mtime: Date? = nil, observedEnds: [Int: Date] = [:],
                            pricing: [String: ModelPricing] = Pricing.table()) -> SessionInspection {
        guard let data = try? Data(contentsOf: file) else {
            return SessionInspection(metrics: SessionMetrics(), steps: [])
        }
        let afterRead = try? URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stableMtime: Date? = {
            guard let mtime, afterRead?.contentModificationDate == mtime,
                  afterRead?.fileSize == data.count else { return nil }
            return mtime
        }()
        var steps: [SessionStep] = []
        var unpriced = Set<String>()
        var explicitWindow: Int?
        var currentContextOverride: Int?
        var hasCurrentContextOverride = false
        switch kind {
        case .claude:
            if let text = String(data: data, encoding: .utf8) {
                let parsed = parseClaudeSteps(text.split(separator: "\n"), pricing: pricing)
                steps = parsed.steps
                unpriced = parsed.unpriced
            }
        case .codex:
            if let text = String(data: data, encoding: .utf8) {
                let parsed = parseCodexSteps(text.split(separator: "\n"), pricing: pricing,
                                             fallbackModel: fallbackModel)
                steps = parsed.steps
                unpriced = parsed.unpriced
                explicitWindow = parsed.contextWindow
            }
        case .gemini:
            let antigravity = isAntigravityTranscript(file)
            var activeMessages: [[String: Any]] = []
            var usageMessages: [[String: Any]] = []
            if file.pathExtension == "json" {
                let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                activeMessages = root["messages"] as? [[String: Any]] ?? []
                usageMessages = activeMessages
            } else if let text = String(data: data, encoding: .utf8) {
                let records = text.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                if antigravity {
                    activeMessages = records
                    usageMessages = records
                } else {
                    activeMessages = replayGeminiLog(records).messages
                    usageMessages = allGeminiUsageMessages(from: records)
                }
            }
            let parsed = parseGeminiSteps(usageMessages, antigravity: antigravity,
                                          fileModified: stableMtime, observedEnds: observedEnds,
                                          pricing: pricing)
            steps = parsed.steps
            unpriced = parsed.unpriced
            if !antigravity {
                let activeParsed = parseGeminiSteps(activeMessages, antigravity: false,
                                                    fileModified: stableMtime, observedEnds: observedEnds,
                                                    pricing: pricing)
                currentContextOverride = activeParsed.steps.last?.contextTokens
                hasCurrentContextOverride = true
            }
        }
        annotateAnomalies(&steps)
        let metrics = summarizeMetrics(steps: steps, fallbackModel: fallbackModel,
                                       explicitContextWindow: explicitWindow,
                                       currentContextOverride: currentContextOverride,
                                       hasCurrentContextOverride: hasCurrentContextOverride)
        let recent = Array(steps.suffix(maxInspectionSteps).reversed())
        return SessionInspection(metrics: metrics, steps: recent,
                                 unpricedModels: unpriced.sorted(),
                                 totalStepCount: steps.count)
    }

    static func summarizeMetrics(steps: [SessionStep], fallbackModel: String,
                                 explicitContextWindow: Int?,
                                 currentContextOverride: Int? = nil,
                                 hasCurrentContextOverride: Bool = false) -> SessionMetrics {
        guard !steps.isEmpty else { return SessionMetrics() }
        // 以最新一步（或回退后的当前活跃分支最新一步）为准：缺少可靠的单步上下文时
        // 留空显示未知，不回退更早步骤的旧值冒充当前上下文。
        let latestContext = hasCurrentContextOverride ? currentContextOverride : steps.last?.contextTokens
        let latestModel = steps.last(where: { !$0.model.isEmpty })?.model ?? fallbackModel
        var window = explicitContextWindow ?? modelContextWindow(for: latestModel)
        if let ctx = latestContext, let win = window, ctx > win {
            window = nil
        }
        let totalPrompt = steps.reduce(0) { $0 + $1.totalPromptTokens }
        let totalCacheRead = steps.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheHitRate = totalPrompt > 0 ? Double(totalCacheRead) / Double(totalPrompt) : nil
        let pricedCosts = steps.compactMap(\.cost)
        let sessionCost = pricedCosts.isEmpty ? nil : pricedCosts.reduce(0, +)
        let totalTokens = steps.reduce(0) { $0 + $1.totalTokens }
        return SessionMetrics(contextTokens: latestContext,
                              contextWindow: window,
                              cacheHitRate: cacheHitRate,
                              sessionCost: sessionCost,
                              totalTokens: totalTokens)
    }

    /// 确定性异常标记：低缓存（输入+缓存 ≥ 10K 且命中 < 50%）、慢响应（≥ 30s）、
    /// 上下文压缩（较上一步下降 > 30% 且降幅 ≥ 10K）。
    static func annotateAnomalies(_ steps: inout [SessionStep]) {
        var previousContext: Int?
        for i in steps.indices {
            var flags: [StepAnomaly] = []
            if steps[i].totalPromptTokens >= 10_000,
               let hit = steps[i].cacheHitRate, hit < 0.5 {
                flags.append(.lowCache)
            }
            if let duration = steps[i].durationSeconds, duration >= 30.0 {
                flags.append(.slowResponse)
            }
            if let cur = steps[i].contextTokens {
                if let prev = previousContext, prev > 0,
                   prev - cur >= 10_000,
                   Double(cur) / Double(prev) < 0.7 {
                    flags.append(.compaction)
                }
                previousContext = cur
            }
            steps[i].anomalies = flags
        }
    }

    private static func pricingModelKey(_ rawModel: String, kind: AgentKind,
                                        pricing: [String: ModelPricing]) -> String {
        switch kind {
        case .gemini:
            return StatusService.normalizedGeminiModel(rawModel)
        case .claude:
            let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if pricing[normalized] != nil { return normalized }
            let prefixed = normalized.hasPrefix("claude-") ? normalized : "claude-\(normalized)"
            return pricing[prefixed] != nil ? prefixed : normalized
        case .codex:
            return rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func stepCost(rawModel: String, kind: AgentKind,
                                 input: Int, cacheRead: Int, cacheWrite: Int,
                                 output: Int, reasoning: Int,
                                 pricing: [String: ModelPricing],
                                 unpriced: inout Set<String>) -> Double? {
        var categories: [String: Int] = [:]
        if input > 0 { categories["input"] = input }
        if cacheRead > 0 { categories["cache_read"] = cacheRead }
        if cacheWrite > 0 { categories["cache_write"] = cacheWrite }
        if output > 0 { categories["output"] = output }
        if reasoning > 0 { categories["reasoning"] = reasoning }
        guard !categories.isEmpty else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            unpriced.insert("unknown")
            return nil
        }
        let key = pricingModelKey(trimmed, kind: kind, pricing: pricing)
        if let cost = Pricing.cost(model: key, categories: categories, table: pricing) {
            return cost
        }
        unpriced.insert(key)
        return nil
    }

    static func parseClaudeSteps(_ lines: [Substring], pricing: [String: ModelPricing])
        -> (steps: [SessionStep], unpriced: Set<String>) {
        struct Entry {
            var start: Date?
            var end: Date?
            var model: String
            var input: Int
            var cacheRead: Int
            var cacheWrite: Int
            var output: Int
            var final: Bool
        }
        var lastInput: Date?
        var byID: [String: Entry] = [:]
        var order: [String] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let ts = (obj["timestamp"] as? String).flatMap(StatusService.timestamp)
            if type == "user" {
                lastInput = ts
            } else if type == "assistant", let msg = obj["message"] as? [String: Any],
                      let id = msg["id"] as? String,
                      let rawModel = msg["model"] as? String,
                      rawModel != "<synthetic>" {
                let usage = msg["usage"] as? [String: Any]
                let input = max(0, (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0)
                let cacheRead = max(0, (usage?["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0)
                let cacheWrite = max(0, (usage?["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0)
                let output = max(0, (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0)
                let final = msg["stop_reason"] is String
                if var e = byID[id] {
                    if let ts { e.end = ts }
                    e.input = max(e.input, input)
                    e.cacheRead = max(e.cacheRead, cacheRead)
                    e.cacheWrite = max(e.cacheWrite, cacheWrite)
                    e.output = max(e.output, output)
                    e.final = e.final || final
                    byID[id] = e
                } else {
                    byID[id] = Entry(start: lastInput, end: ts, model: rawModel,
                                     input: input, cacheRead: cacheRead,
                                     cacheWrite: cacheWrite, output: output, final: final)
                    order.append(id)
                }
            }
        }
        var steps: [SessionStep] = []
        var unpriced = Set<String>()
        for id in order {
            guard let e = byID[id] else { continue }
            let prompt = e.input + e.cacheRead + e.cacheWrite
            guard prompt + e.output > 0 else { continue }
            let duration: TimeInterval? = {
                guard e.final, let start = e.start, let end = e.end else { return nil }
                let dt = end.timeIntervalSince(start)
                return dt > 0 ? dt : nil
            }()
            let cost = stepCost(rawModel: e.model, kind: .claude,
                                input: e.input, cacheRead: e.cacheRead, cacheWrite: e.cacheWrite,
                                output: e.output, reasoning: 0,
                                pricing: pricing, unpriced: &unpriced)
            let displayModel = e.model.replacingOccurrences(of: "claude-", with: "")
            steps.append(SessionStep(
                id: "claude:\(id)",
                index: steps.count + 1,
                timestamp: e.end,
                model: displayModel,
                inputTokens: e.input,
                cacheReadTokens: e.cacheRead,
                cacheWriteTokens: e.cacheWrite,
                outputTokens: e.output,
                reasoningTokens: 0,
                contextTokens: prompt > 0 ? prompt : nil,
                durationSeconds: duration,
                cost: cost
            ))
        }
        return (steps, unpriced)
    }

    static func parseCodexSteps(_ lines: [Substring], pricing: [String: ModelPricing],
                                fallbackModel: String,
                                isPartialTail: Bool = false)
        -> (steps: [SessionStep], unpriced: Set<String>, contextWindow: Int?) {
        struct RawCodexStep {
            var id: String
            var timestamp: Date?
            var model: String?
            var input: Int
            var cached: Int
            var output: Int
            var reasoning: Int
            var uncategorizedTotal: Int
            var contextTokens: Int?
            var duration: TimeInterval?
            var rawInput: Int
            var rawOutput: Int
        }
        var rawSteps: [RawCodexStep] = []
        var currentModel: String?
        var firstModel: String?
        var contextWindow: Int?
        var lastInput: Date?
        var codexStart: Date?
        var inResponse = false
        var previousTotal: Int?
        var previousFields: [String: Int] = [:]
        // 真实 Codex 日志会为同一次调用先后写 token_usage_record 与 token_count：
        // 记录刚追加的 token_usage_record 索引，遇到紧随其后的配对 token_count 时合并而非双计。
        var pendingRecordIndex: Int?

        func makeStep(ts: Date?, fields: [String: Int], totalOnly: Int, hasLastUsage: Bool,
                      suffix: String, index: Int) -> RawCodexStep? {
            let rawInput = max(0, fields["input_tokens"] ?? 0)
            let cached = max(0, fields["cached_input_tokens"] ?? 0)
            let rawOutput = max(0, fields["output_tokens"] ?? 0)
            let reasoning = max(0, fields["reasoning_output_tokens"] ?? 0)
            let nonCachedInput = max(0, rawInput - cached)
            let nonReasoningOutput = max(0, rawOutput - reasoning)
            let categorized = nonCachedInput + cached + nonReasoningOutput + reasoning
            let uncategorized = categorized > 0 ? 0 : max(0, totalOnly)
            guard categorized + uncategorized > 0 else { return nil }
            let duration: TimeInterval? = {
                guard inResponse, let start = codexStart, let ts else { return nil }
                let dt = ts.timeIntervalSince(start)
                return dt > 0 ? dt : nil
            }()
            // Codex 只有在存在单步 last_token_usage 时才能可靠得出上下文长度，
            // 绝不拿会话累计 total_token_usage 冒充当前上下文。
            let contextTokens = (hasLastUsage && rawInput > 0) ? rawInput : nil
            return RawCodexStep(
                id: "codex:\(index):\(suffix)",
                timestamp: ts,
                model: currentModel,
                input: nonCachedInput,
                cached: cached,
                output: nonReasoningOutput,
                reasoning: reasoning,
                uncategorizedTotal: uncategorized,
                contextTokens: contextTokens,
                duration: duration,
                rawInput: rawInput,
                rawOutput: rawOutput
            )
        }

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            if let m = payload["model"] as? String, !m.isEmpty {
                currentModel = m
                if firstModel == nil { firstModel = m }
            }
            let type = obj["type"] as? String
            let ptype = payload["type"] as? String ?? ""
            let ts = (obj["timestamp"] as? String).flatMap(StatusService.timestamp)
            if type == "token_usage_record", let usage = payload["usage"] as? [String: Any] {
                let fields = [
                    "input_tokens": (usage["input_tokens"] as? NSNumber)?.intValue ?? 0,
                    "cached_input_tokens": (usage["cached_input_tokens"] as? NSNumber)?.intValue ?? 0,
                    "output_tokens": (usage["output_tokens"] as? NSNumber)?.intValue ?? 0,
                    "reasoning_output_tokens": (usage["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0,
                ]
                let totalOnly = (usage["total_tokens"] as? NSNumber)?.intValue ?? 0
                if let step = makeStep(ts: ts, fields: fields, totalOnly: totalOnly,
                                       hasLastUsage: (fields["input_tokens"] ?? 0) > 0,
                                       suffix: "rec", index: rawSteps.count + 1) {
                    pendingRecordIndex = rawSteps.count
                    rawSteps.append(step)
                }
                codexStart = nil
                inResponse = false
            } else if ptype == "token_count", let info = payload["info"] as? [String: Any] {
                if let win = (info["model_context_window"] as? NSNumber)?.intValue, win > 0 {
                    contextWindow = win
                }
                guard let total = info["total_token_usage"] as? [String: Any],
                      let cumulative = (total["total_tokens"] as? NSNumber)?.intValue else { continue }
                let lastUsage = info["last_token_usage"] as? [String: Any]
                func extract(_ dict: [String: Any]) -> [String: Int] {
                    [
                        "input_tokens": (dict["input_tokens"] as? NSNumber)?.intValue ?? 0,
                        "cached_input_tokens": (dict["cached_input_tokens"] as? NSNumber)?.intValue ?? 0,
                        "output_tokens": (dict["output_tokens"] as? NSNumber)?.intValue ?? 0,
                        "reasoning_output_tokens": (dict["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0,
                    ]
                }
                let cumulativeFields = extract(total)
                // 尾部采样（>128 KiB）若首条 token_count 只有累计值且没有 last_token_usage，
                // 无法得知截断点之前的增量基线，只能记为基线并跳过，不能把历史累计当近期新调用。
                if isPartialTail, previousTotal == nil, lastUsage == nil {
                    previousTotal = cumulative
                    previousFields = cumulativeFields
                    pendingRecordIndex = nil
                    continue
                }
                let deltaFields: [String: Int]
                let deltaTotal: Int
                if let previousTotal, cumulative == previousTotal {
                    deltaFields = [:]
                    deltaTotal = 0
                } else if let lastUsage {
                    deltaFields = extract(lastUsage)
                    deltaTotal = max(0, (lastUsage["total_tokens"] as? NSNumber)?.intValue ?? 0)
                } else if let previousTotal {
                    deltaFields = cumulativeFields.reduce(into: [:]) { acc, entry in
                        acc[entry.key] = max(0, entry.value - (previousFields[entry.key] ?? 0))
                    }
                    deltaTotal = max(0, cumulative - previousTotal)
                } else {
                    deltaFields = cumulativeFields
                    deltaTotal = max(0, cumulative)
                }
                previousTotal = cumulative
                previousFields = cumulativeFields
                guard !deltaFields.isEmpty || deltaTotal > 0 else { continue }
                if let idx = pendingRecordIndex, rawSteps.indices.contains(idx) {
                    // 合并配对的 token_count 到刚记录的 token_usage_record，保留耗时并补全上下文/细分字段
                    let prev = rawSteps[idx]
                    let rawIn = max(0, deltaFields["input_tokens"] ?? 0)
                    let cached = max(0, deltaFields["cached_input_tokens"] ?? 0)
                    let rawOut = max(0, deltaFields["output_tokens"] ?? 0)
                    let reasoning = max(0, deltaFields["reasoning_output_tokens"] ?? 0)
                    let nonCachedIn = max(0, rawIn - cached)
                    let nonReasoningOut = max(0, rawOut - reasoning)
                    let categorized = nonCachedIn + cached + nonReasoningOut + reasoning
                    rawSteps[idx] = RawCodexStep(
                        id: prev.id,
                        timestamp: ts ?? prev.timestamp,
                        model: prev.model ?? currentModel,
                        input: nonCachedIn,
                        cached: cached,
                        output: nonReasoningOut,
                        reasoning: reasoning,
                        uncategorizedTotal: categorized > 0 ? 0 : max(deltaTotal, prev.uncategorizedTotal),
                        contextTokens: (lastUsage != nil && rawIn > 0) ? rawIn : prev.contextTokens,
                        duration: prev.duration,
                        rawInput: rawIn,
                        rawOutput: rawOut
                    )
                    pendingRecordIndex = nil
                } else if let step = makeStep(ts: ts, fields: deltaFields, totalOnly: deltaTotal,
                                              hasLastUsage: lastUsage != nil,
                                              suffix: "cnt", index: rawSteps.count + 1) {
                    rawSteps.append(step)
                    codexStart = nil
                    inResponse = false
                }
            } else if type == "response_item" {
                pendingRecordIndex = nil
                if ptype.hasSuffix("_output")
                    || (ptype == "message" && payload["role"] as? String != "assistant") {
                    lastInput = ts
                } else if !inResponse {
                    inResponse = true
                    codexStart = lastInput
                }
            } else if type == "event_msg", ptype == "user_message" {
                pendingRecordIndex = nil
                lastInput = ts
            }
        }
        // 与 StatusService.codexUsageEvents 一致：模型声明前的开头用量归属文件首个声明的模型
        let defaultModel = firstModel ?? fallbackModel
        var steps: [SessionStep] = []
        var unpriced = Set<String>()
        for (idx, raw) in rawSteps.enumerated() {
            let resolvedModel = raw.model ?? defaultModel
            let cost = stepCost(rawModel: resolvedModel, kind: .codex,
                                input: raw.input, cacheRead: raw.cached, cacheWrite: 0,
                                output: raw.output, reasoning: raw.reasoning,
                                pricing: pricing, unpriced: &unpriced)
            steps.append(SessionStep(
                id: raw.id,
                index: idx + 1,
                timestamp: raw.timestamp,
                model: resolvedModel,
                inputTokens: raw.input,
                cacheReadTokens: raw.cached,
                cacheWriteTokens: 0,
                outputTokens: raw.output,
                reasoningTokens: raw.reasoning,
                contextTokens: raw.contextTokens,
                durationSeconds: raw.duration,
                cost: cost,
                uncategorizedTotalTokens: raw.uncategorizedTotal
            ))
        }
        return (steps, unpriced, contextWindow)
    }

    static func parseGeminiSteps(_ messages: [[String: Any]], antigravity: Bool,
                                 fileModified: Date? = nil, observedEnds: [Int: Date] = [:],
                                 pricing: [String: ModelPricing])
        -> (steps: [SessionStep], unpriced: Set<String>) {
        var steps: [SessionStep] = []
        var unpriced = Set<String>()
        if antigravity {
            for i in messages.indices {
                let msg = messages[i]
                guard msg["type"] as? String == "PLANNER_RESPONSE",
                      (msg["status"] as? String ?? "DONE") == "DONE" else { continue }
                let input = max(0, (msg["input_tokens"] as? NSNumber)?.intValue ?? 0)
                let cacheRead = max(0, (msg["cache_read_tokens"] as? NSNumber)?.intValue ?? 0)
                let output = max(0, (msg["output_tokens"] as? NSNumber)?.intValue ?? 0)
                guard input + cacheRead + output > 0 else { continue }
                let start = StatusService.timestamp(msg["created_at"])
                let stepIdx = (msg["step_index"] as? NSNumber)?.intValue
                let end: Date? = {
                    guard let start else { return nil }
                    if messages.indices.contains(i + 1) {
                        let next = messages[i + 1]
                        if next["type"] as? String != "USER_INPUT",
                           next["source"] as? String != "USER_EXPLICIT",
                           next["source"] as? String != "SYSTEM" {
                            return StatusService.timestamp(next["created_at"])
                        } else if let stepIdx {
                            return observedEnds[stepIdx]
                        }
                        return nil
                    } else if let stepIdx, let recorded = observedEnds[stepIdx] {
                        return recorded
                    } else if let mtime = fileModified, mtime.timeIntervalSince(start) <= 600 {
                        return mtime
                    }
                    return nil
                }()
                let duration: TimeInterval? = {
                    guard let start, let end else { return nil }
                    let dt = end.timeIntervalSince(start)
                    return dt > 0 ? dt : nil
                }()
                let rawModel = msg["model"] as? String ?? ""
                let cost = stepCost(rawModel: rawModel, kind: .gemini,
                                    input: input, cacheRead: cacheRead, cacheWrite: 0,
                                    output: output, reasoning: 0,
                                    pricing: pricing, unpriced: &unpriced)
                let context = input + cacheRead
                steps.append(SessionStep(
                    id: "agy:\(stepIdx ?? i)",
                    index: steps.count + 1,
                    timestamp: end ?? start,
                    model: rawModel,
                    inputTokens: input,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: 0,
                    outputTokens: output,
                    reasoningTokens: 0,
                    contextTokens: context > 0 ? context : nil,
                    durationSeconds: duration,
                    cost: cost
                ))
            }
        } else {
            var lastInput: Date?
            for (i, msg) in messages.enumerated() {
                let type = msg["type"] as? String
                if type == "user" {
                    lastInput = StatusService.timestamp(msg["timestamp"])
                } else if type == "gemini" {
                    let ts = StatusService.timestamp(msg["timestamp"])
                    if let tokens = msg["tokens"] as? [String: Any] {
                        let rawInput = max(0, (tokens["input"] as? NSNumber)?.intValue ?? 0)
                        let cached = max(0, (tokens["cached"] as? NSNumber)?.intValue ?? 0)
                        let output = max(0, (tokens["output"] as? NSNumber)?.intValue ?? 0)
                        let thoughts = max(0, (tokens["thoughts"] as? NSNumber)?.intValue ?? 0)
                        let tool = max(0, (tokens["tool"] as? NSNumber)?.intValue ?? 0)
                        let nonCachedInput = max(0, rawInput - cached) + tool
                        if nonCachedInput + cached + output + thoughts > 0 {
                            let duration: TimeInterval? = {
                                guard let start = lastInput, let end = ts else { return nil }
                                let dt = end.timeIntervalSince(start)
                                return dt > 0 ? dt : nil
                            }()
                            let rawModel = msg["model"] as? String ?? ""
                            let cost = stepCost(rawModel: rawModel, kind: .gemini,
                                                input: nonCachedInput, cacheRead: cached, cacheWrite: 0,
                                                output: output, reasoning: thoughts,
                                                pricing: pricing, unpriced: &unpriced)
                            let id = (msg["id"] as? String) ?? "\(i)"
                            steps.append(SessionStep(
                                id: "gemini:\(id)",
                                index: steps.count + 1,
                                timestamp: ts,
                                model: rawModel,
                                inputTokens: nonCachedInput,
                                cacheReadTokens: cached,
                                cacheWriteTokens: 0,
                                outputTokens: output,
                                reasoningTokens: thoughts,
                                contextTokens: rawInput > 0 ? rawInput : nil,
                                durationSeconds: duration,
                                cost: cost
                            ))
                        }
                    }
                    let toolEnd = (msg["toolCalls"] as? [[String: Any]])?
                        .compactMap { StatusService.timestamp($0["timestamp"]) }
                        .max()
                    if let nextStart = toolEnd ?? ts { lastInput = nextStart }
                }
            }
        }
        return (steps, unpriced)
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

    /// Gemini CLI 按终端跟踪：同一个会话只保留最新的匹配方式（打开的会话文件，
    /// 或者没打开时的 cwd），宽限期也按终端算。按键跟踪时，会话在两种方式
    /// 之间切换会让旧键留在宽限期里，一个会话算成两个存活会话。
    private enum GeminiMatch { case transcript(String), cwd(String) }
    private var gemini: [String: (match: GeminiMatch, misses: Int)] = [:]

    /// 键为 transcript 路径，或 cwd 回退的 "cwd#<encoded>#<i>"（claude），
    /// 或 "agy#<i>"（Antigravity）；Gemini CLI 另按进程跟踪。
    mutating func update(snapshots: [ProcessDiscovery.Snapshot]) -> Result {
        var seen = Set<String>()
        var cwdIndex: [String: Int] = [:]
        var agyIndex = 0
        var geminiSeen: [String: GeminiMatch] = [:]
        for snap in snapshots {
            if snap.kind == .gemini, !snap.antigravity {
                if let path = snap.transcriptPath { geminiSeen[snap.tty] = .transcript(path) }
                else if let cwd = snap.cwd { geminiSeen[snap.tty] = .cwd(cwd) }
            } else if let path = snap.transcriptPath {
                seen.insert(path)
            } else if snap.antigravity {
                seen.insert("agy#\(agyIndex)")
                agyIndex += 1
            } else if let cwd = snap.cwd, snap.kind == .claude {
                let key = "cwd#\(sanitizedClaudeProjectPath(cwd))"
                let i = cwdIndex[key, default: 0]
                cwdIndex[key] = i + 1
                seen.insert("\(key)#\(i)")
            }
        }
        for p in seen { missCounts[p] = 0 }
        for (p, n) in missCounts where !seen.contains(p) {
            if n + 1 >= 2 { missCounts.removeValue(forKey: p) } else { missCounts[p] = n + 1 }
        }
        for (tty, entry) in gemini where geminiSeen[tty] == nil {
            if entry.misses + 1 >= 2 { gemini.removeValue(forKey: tty) } else { gemini[tty]?.misses += 1 }
        }
        for (tty, match) in geminiSeen { gemini[tty] = (match, 0) }
        var result = Result()
        for entry in gemini.values {
            switch entry.match {
            case let .transcript(path): result.live.insert(path)
            case let .cwd(cwd): result.geminiCwdCounts[cwd, default: 0] += 1
            }
        }
        for key in missCounts.keys {
            if key.hasPrefix("cwd#") {
                let encoded = String(key.dropFirst(4).split(separator: "#")[0])
                result.claudeCwdCounts[encoded, default: 0] += 1
            } else if key.hasPrefix("agy#") {
                result.antigravityCount += 1
            } else {
                result.live.insert(key)
            }
        }
        return result
    }

    mutating func reset() {
        missCounts = [:]
        gemini = [:]
    }
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
    /// 独立的详情解析队列：打开长会话时绝不阻塞 3 秒一次的存活轮询。
    private let inspectionQueue = DispatchQueue(label: "ai.elink.agent-session-inspect", qos: .userInitiated)
    private let inspectLock = NSLock()
    private var inspectGeneration: UInt64 = 0

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

    func inspect(session: AgentSession, completion: @escaping (SessionInspection) -> Void) {
        inspectLock.lock()
        inspectGeneration &+= 1
        let gen = inspectGeneration
        inspectLock.unlock()
        inspectionQueue.async { [weak self] in
            guard let self else { return }
            // 若期间已有更新的刷新请求排队，跳过过时的全量解析
            self.inspectLock.lock()
            let current = self.inspectGeneration
            self.inspectLock.unlock()
            guard gen == current else { return }
            let result = self.scanner.inspect(session: session)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func clearInspectionCache() {
        inspectLock.lock()
        inspectGeneration &+= 1
        inspectLock.unlock()
        inspectionQueue.async { [weak self] in self?.scanner.clearInspectionCache() }
    }

    /// 面板关闭时调用，避免重开时用陈旧的 miss 计数闪现过期存活状态。
    func reset() {
        clearInspectionCache()
        queue.async { [weak self] in self?.tracker.reset() }
    }
}
