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
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date.distantFuture
        var lines: [String] = []
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n").map(String.init))
        }
        let models = Self.claudeModelUsage(lines: lines, start: start, end: end)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models
        )
    }

    private func readCodex() -> AgentStatus {
        let root = URL(fileURLWithPath: ("~/.codex/sessions" as NSString).expandingTildeInPath)
        let files = jsonlFiles(root)
        let latest = latestModification(files)
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date.distantFuture
        var sessions: [[String]] = []
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTimestamp = ""
        for file in files where (modification(file) ?? .distantPast) >= start {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").map(String.init)
            sessions.append(lines)
            for line in lines where line.contains("\"token_count\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { continue }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let timestamp = object["timestamp"] as? String ?? ""
                    if timestamp >= latestRateLimitsTimestamp {
                        latestRateLimitsTimestamp = timestamp
                        latestRateLimits = limits
                    }
                }
            }
        }
        let models = Self.codexModelUsage(sessions: sessions, start: start, end: end)
        let windows = latestRateLimits.map(UsageFetcher.codexLogWindows)
        return AgentStatus(
            state: state(latest),
            tokensToday: models.reduce(0) { $0 + $1.tokens },
            modelUsageToday: models,
            primary: windows?.primary ?? UsageWindow(),
            weekly: windows?.weekly ?? UsageWindow()
        )
    }

    static func claudeModelUsage(lines: [String], start: Date, end: Date) -> [ModelUsage] {
        var messages: [String: ModelUsage] = [:]
        for line in lines where line.contains("\"usage\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = timestamp(object["timestamp"]),
                  timestamp >= start, timestamp < end,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens",
                          "cache_read_input_tokens"].reduce(0) {
                $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0)
            }
            guard tokens > 0 else { continue }
            let identifier = (message["id"] as? String) ?? (object["uuid"] as? String) ?? line
            let model = normalizedModel(message["model"])
            if tokens > (messages[identifier]?.tokens ?? -1) {
                messages[identifier] = ModelUsage(model: model, tokens: tokens)
            }
        }
        return aggregate(messages.values)
    }

    static func codexModelUsage(sessions: [[String]], start: Date, end: Date) -> [ModelUsage] {
        var totals: [String: Int] = [:]
        for lines in sessions {
            var model = "unknown"
            var previousTotal: Int?
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any] else { continue }
                if let value = payload["model"] as? String, !value.isEmpty {
                    model = value
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let cumulative = (total["total_tokens"] as? NSNumber)?.intValue else { continue }

                let last = (info["last_token_usage"] as? [String: Any])
                    .flatMap { ($0["total_tokens"] as? NSNumber)?.intValue }
                let delta: Int
                if let previousTotal, cumulative == previousTotal {
                    delta = 0
                } else if let last {
                    delta = last
                } else if let previousTotal {
                    delta = max(0, cumulative - previousTotal)
                } else {
                    delta = cumulative
                }
                previousTotal = cumulative

                guard delta > 0,
                      let date = timestamp(object["timestamp"]),
                      date >= start, date < end else { continue }
                totals[normalizedModel(model), default: 0] += delta
            }
        }
        return sorted(totals)
    }

    private static func aggregate(_ usage: Dictionary<String, ModelUsage>.Values) -> [ModelUsage] {
        var totals: [String: Int] = [:]
        for value in usage { totals[value.model, default: 0] += value.tokens }
        return sorted(totals)
    }

    private static func sorted(_ totals: [String: Int]) -> [ModelUsage] {
        totals.map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
    }

    private static func normalizedModel(_ value: Any?) -> String {
        guard let model = value as? String else { return "unknown" }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return fractionalTimestamp.date(from: value) ?? basicTimestamp.date(from: value)
    }

    private static let fractionalTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicTimestamp = ISO8601DateFormatter()

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
