import Foundation

final class StatusService {
    private struct HookState {
        let state: String
        let at: Date
    }

    private let usage: UsageFetcher
    private let lock = NSLock()
    private var cached: BridgeSnapshot?
    private var cachedAt = Date.distantPast
    private var hooks: [String: HookState] = [:]
    private var needsInput: [String: Date] = [:]

    init(usage: UsageFetcher) { self.usage = usage }

    func snapshot() -> BridgeSnapshot {
        lock.holding {
            var value: BridgeSnapshot
            if let cached, Date().timeIntervalSince(cachedAt) < 5 {
                value = cached
            } else {
                value = readLogs()
                cached = value
                cachedAt = Date()
            }
            value.generatedAt = Date()
            value.claude = overlay(value.claude, provider: "claude", usage: usage.claude)
            value.codex = overlay(value.codex, provider: "codex", usage: usage.codex)
            value.usageFetchedAt = [usage.claude.fetchedAt, usage.codex.fetchedAt].compactMap { $0 }.max()
            return value
        }
    }

    func recordEvent(agent: String, event: String, message: String?) {
        guard ["claude", "codex"].contains(agent) else { return }
        lock.holding {
            let now = Date()
            if ["PermissionRequest", "Elicitation"].contains(event)
                || (event == "Notification" && isPermission(message)) {
                needsInput[agent] = now
                return
            }
            let working = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart",
                           "SubagentStop", "PreCompact", "PostCompact", "WorktreeCreate"]
            let idle = ["Stop", "SessionEnd", "SessionStart"]
            if working.contains(event) { hooks[agent] = HookState(state: "working", at: now) }
            else if idle.contains(event) { hooks[agent] = HookState(state: "idle", at: now) }
            else { return }
            needsInput.removeValue(forKey: agent)
        }
    }

    private func overlay(_ input: AgentStatus, provider: String, usage: ProviderUsage) -> AgentStatus {
        var value = input
        value.primary = usage.primary.percent == nil ? value.primary : usage.primary
        value.weekly = usage.weekly.percent == nil ? value.weekly : usage.weekly
        value.error = usage.error
        if let hook = hooks[provider] {
            let age = Date().timeIntervalSince(hook.at)
            if hook.state == "working", age < 600 { value.state = "working" }
            if hook.state == "idle", age < 60, value.state == "working" { value.state = "idle" }
        }
        value.needsInput = needsInput[provider].map { Date().timeIntervalSince($0) < 300 } ?? false
        return value
    }

    private func readLogs() -> BridgeSnapshot {
        BridgeSnapshot(
            claude: readClaude(),
            codex: readCodex(),
            generatedAt: Date(),
            usageFetchedAt: nil
        )
    }

    private func readClaude() -> AgentStatus {
        let root = URL(fileURLWithPath: ("~/.claude/projects" as NSString).expandingTildeInPath)
        let files = jsonlFiles(root)
        let latest = latestModification(files)
        let start = Calendar.current.startOfDay(for: Date())
        var tokens = 0
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                    tokens += (usage[key] as? NSNumber)?.intValue ?? 0
                }
            }
        }
        return AgentStatus(state: state(latest), tokensToday: tokens)
    }

    private func readCodex() -> AgentStatus {
        let root = URL(fileURLWithPath: ("~/.codex/sessions" as NSString).expandingTildeInPath)
        let files = jsonlFiles(root)
        let latest = latestModification(files)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let marker = String(format: "/%04d/%02d/%02d/", components.year ?? 0,
                            components.month ?? 0, components.day ?? 0)
        var tokens = 0
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTimestamp = ""
        for file in files where file.path.contains(marker) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var sessionMaximum = 0
            for line in text.split(separator: "\n") where line.contains("\"token_count\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { continue }
                sessionMaximum = max(sessionMaximum, (total["total_tokens"] as? NSNumber)?.intValue ?? 0)
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let timestamp = object["timestamp"] as? String ?? ""
                    if timestamp >= latestRateLimitsTimestamp {
                        latestRateLimitsTimestamp = timestamp
                        latestRateLimits = limits
                    }
                }
            }
            tokens += sessionMaximum
        }
        let windows = latestRateLimits.map(UsageFetcher.codexLogWindows)
        return AgentStatus(
            state: state(latest),
            tokensToday: tokens,
            primary: windows?.primary ?? UsageWindow(),
            weekly: windows?.weekly ?? UsageWindow()
        )
    }

    private func jsonlFiles(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func latestModification(_ files: [URL]) -> Date? { files.compactMap(modification).max() }
    private func modification(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    private func state(_ date: Date?) -> String {
        guard let age = date.map({ Date().timeIntervalSince($0) }) else { return "offline" }
        if age < 20 { return "working" }
        if age < 1800 { return "idle" }
        return "offline"
    }
    private func isPermission(_ message: String?) -> Bool {
        guard let text = message?.lowercased() else { return false }
        return text.contains("permission") || text.contains("approve") || text.contains("approval")
    }
}
