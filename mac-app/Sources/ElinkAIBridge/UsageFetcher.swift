import Foundation

final class UsageFetcher {
    private let lock = NSLock()
    private let cacheStore: UsageStore?
    private var storedClaude = ProviderUsage()
    private var storedCodex = ProviderUsage()
    private var fetching = false
    private var nextAllowed = Date.distantPast
    private var lastLogSummary = ""
    private var timer: Timer?
    private var refreshCompletions: [() -> Void] = []
    var onUpdate: (() -> Void)?

    var claude: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedClaude) } }
    var codex: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedCodex) } }

    init(cacheStore: UsageStore? = nil) {
        self.cacheStore = cacheStore
        storedClaude = cacheStore?.cachedUsage(provider: "claude") ?? ProviderUsage()
        storedCodex = cacheStore?.cachedUsage(provider: "codex") ?? ProviderUsage()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        var completeWithoutRefresh = false
        let shouldStart = lock.holding { () -> Bool in
            if fetching {
                if let completion { refreshCompletions.append(completion) }
                return false
            }
            guard force || Date() >= nextAllowed else {
                completeWithoutRefresh = completion != nil
                return false
            }
            if let completion { refreshCompletions.append(completion) }
            fetching = true
            return true
        }
        if completeWithoutRefresh {
            DispatchQueue.main.async { completion?() }
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let claude = self.fetchClaude()
            let codex = self.fetchCodex()
            if claude.error == nil || claude.primary.percent != nil || claude.weekly.percent != nil {
                self.cacheStore?.cacheUsage(provider: "claude", usage: claude)
            }
            if codex.error == nil || codex.primary.percent != nil || codex.weekly.percent != nil {
                self.cacheStore?.cacheUsage(provider: "codex", usage: codex)
            }
            let completions = self.lock.holding { () -> [() -> Void] in
                self.storedClaude = Self.keepLastGood(old: self.storedClaude, new: claude)
                self.storedCodex = Self.keepLastGood(old: self.storedCodex, new: codex)
                self.fetching = false
                let rateLimited = claude.error?.contains("429") == true || codex.error?.contains("429") == true
                self.nextAllowed = Date().addingTimeInterval(rateLimited ? 300 : 60)
                let summary = "usage claude=\(Self.describe(claude)) codex=\(Self.describe(codex))"
                if summary != self.lastLogSummary {
                    self.lastLogSummary = summary
                    if claude.error != nil || codex.error != nil {
                        Log.warning(summary, category: "usage")
                    } else {
                        Log.info(summary, category: "usage")
                    }
                }
                let values = self.refreshCompletions
                self.refreshCompletions.removeAll()
                return values
            }
            DispatchQueue.main.async {
                self.onUpdate?()
                completions.forEach { $0() }
            }
        }
    }

    static func describe(_ usage: ProviderUsage) -> String {
        var parts: [String] = []
        if let percent = usage.primary.percent {
            parts.append("primary=\(Int(percent))%")
        }
        if let percent = usage.weekly.percent {
            parts.append("weekly=\(Int(percent))%")
        }
        if usage.isCached { parts.append("cached") }
        if let error = usage.error { parts.append("error=\(error)") }
        return parts.isEmpty ? "n/a" : parts.joined(separator: " ")
    }

    static func keepLastGood(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        let now = Date()
        var current = new
        current.primary = current.primary.discardingIfExpired(at: now)
        current.weekly = current.weekly.discardingIfExpired(at: now)
        let previousPrimary = old.primary.discardingIfExpired(at: now)
        let previousWeekly = old.weekly.discardingIfExpired(at: now)
        let hadGoodValue = previousPrimary.percent != nil || previousWeekly.percent != nil
        guard current.primary.percent == nil, current.weekly.percent == nil, hadGoodValue else {
            return current
        }
        var retained = old
        retained.primary = previousPrimary
        retained.weekly = previousWeekly
        retained.error = new.error
        retained.isCached = true
        return retained
    }

    private static func discardingExpiredWindows(_ usage: ProviderUsage,
                                                  now: Date = Date()) -> ProviderUsage {
        var value = usage
        value.primary = value.primary.discardingIfExpired(at: now)
        value.weekly = value.weekly.discardingIfExpired(at: now)
        return value
    }

    private func fetchClaude() -> ProviderUsage {
        let token: String
        switch Self.claudeToken() {
        case let .success(value):
            token = value
        case let .failure(error):
            if var cached = Self.cachedClaudeUsage() {
                cached.error = "\(error.localizedDescription)，显示状态栏缓存"
                return cached
            }
            return ProviderUsage(error: error.localizedDescription)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, status) = Self.request(request) else {
            return Self.claudeFallback(error: "Claude 用量请求失败")
        }
        guard status == 200 else {
            return Self.claudeFallback(error: "Claude 用量 HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.claudeFallback(error: "Claude 用量响应解析失败")
        }
        let primary = Self.isoWindow(json["five_hour"])
        let weekly = Self.isoWindow(json["seven_day"])
        return ProviderUsage(primary: primary, weekly: weekly, fetchedAt: Date())
    }

    private static func claudeFallback(error: String) -> ProviderUsage {
        guard var cached = cachedClaudeUsage() else { return ProviderUsage(error: error) }
        cached.error = error
        return cached
    }

    private static func cachedClaudeUsage(now: Date = Date()) -> ProviderUsage? {
        let file = URL(fileURLWithPath: ("~/.cache/statusline/last.json" as NSString).expandingTildeInPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) >= 0,
              let data = FileManager.default.contents(atPath: file.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard var usage = claudeStatuslineUsage(json, fetchedAt: modified, now: now) else { return nil }
        let hasResetTime = usage.primary.resetAt != nil || usage.weekly.resetAt != nil
        guard hasResetTime || now.timeIntervalSince(modified) <= 6 * 60 * 60 else { return nil }
        usage.isCached = true
        return usage
    }

    static func claudeStatuslineUsage(_ json: [String: Any], fetchedAt: Date,
                                      now: Date = Date()) -> ProviderUsage? {
        guard let limits = json["rate_limits"] as? [String: Any] else { return nil }
        let primary = statuslineWindow(limits["five_hour"], now: now)
        let weekly = statuslineWindow(limits["seven_day"], now: now)
        guard primary.percent != nil || weekly.percent != nil else { return nil }
        return ProviderUsage(primary: primary, weekly: weekly, fetchedAt: fetchedAt, isCached: true)
    }

    private static func statuslineWindow(_ value: Any?, now: Date) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["used_percentage"] as? NSNumber)?.doubleValue
        let resetAt = (object["resets_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return UsageWindow(
            percent: percent,
            resetMinutes: resetAt.flatMap {
                Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970, now: now)
            },
            resetAt: resetAt
        ).discardingIfExpired(at: now)
    }

    /// 窗口已过期（resets_at <= now）时返回 nil，显示端渲染为 "—"。
    private static func remainingMinutes(untilEpoch epoch: Double, now: Date = Date()) -> Int? {
        let seconds = epoch - now.timeIntervalSince1970
        return seconds > 0 ? Int(seconds / 60) : nil
    }

    private func fetchCodex() -> ProviderUsage {
        let credentials: (token: String, account: String?)
        switch Self.codexCredentials() {
        case let .success(value): credentials = value
        case let .failure(error): return ProviderUsage(error: error.localizedDescription)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = credentials.account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        guard let (data, status) = Self.request(request) else {
            return ProviderUsage(error: "Codex 用量请求失败")
        }
        guard (200...299).contains(status) else {
            let error = status == 401 || status == 403
                ? "Codex 凭据过期，请运行 codex 重新登录"
                : status == 429 ? "Codex 用量 HTTP 429，稍后自动重试"
                : "Codex 用量 HTTP \(status)"
            return ProviderUsage(error: error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else {
            return ProviderUsage(error: "Codex 用量响应解析失败")
        }
        let windows = Self.codexWindows(limits)
        return ProviderUsage(
            primary: windows.primary,
            weekly: windows.weekly,
            fetchedAt: Date()
        )
    }

    static func codexWindows(_ limits: [String: Any]) -> (primary: UsageWindow, weekly: UsageWindow) {
        var primary = UsageWindow()
        var weekly = UsageWindow()
        let values = [limits["primary_window"], limits["secondary_window"]]

        for (index, value) in values.enumerated() {
            guard let object = value as? [String: Any] else { continue }
            let window = epochWindow(object)
            if let seconds = (object["limit_window_seconds"] as? NSNumber)?.intValue {
                if seconds >= 6 * 24 * 60 * 60 {
                    weekly = window
                } else {
                    primary = window
                }
            } else if index == 0 {
                primary = window
            } else {
                weekly = window
            }
        }
        return (primary, weekly)
    }

    static func codexLogWindows(_ limits: [String: Any]) -> (primary: UsageWindow, weekly: UsageWindow) {
        var converted = [String: Any]()
        for (source, target) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
            guard let value = limits[source] as? [String: Any] else { continue }
            var window = value
            if let minutes = (value["window_minutes"] as? NSNumber)?.intValue {
                window["limit_window_seconds"] = minutes * 60
            }
            if let reset = value["resets_at"] { window["reset_at"] = reset }
            converted[target] = window
        }
        return codexWindows(converted)
    }

    private enum CredentialError: LocalizedError {
        case claudeKeychainUnavailable
        case claudeKeychain(Int32)
        case invalidClaudeCredentials
        case missingCodexFile
        case invalidCodexCredentials

        var errorDescription: String? {
            switch self {
            case .claudeKeychainUnavailable:
                return "无法调用 macOS Keychain 读取 Claude 凭据"
            case let .claudeKeychain(status):
                return "Keychain 中未找到或无法访问 Claude 凭据（security \(status)）"
            case .invalidClaudeCredentials:
                return "Claude 凭据格式无效，请运行 claude 重新登录"
            case .missingCodexFile:
                return "未找到 ~/.codex/auth.json，请运行 codex 重新登录"
            case .invalidCodexCredentials:
                return "Codex 凭据格式无效，请运行 codex 重新登录"
            }
        }
    }

    private static func claudeToken() -> Result<String, CredentialError> {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !token.isEmpty {
            return .success(token)
        }
        let file = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        var data = FileManager.default.contents(atPath: file)
        if data == nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
            guard (try? process.run()) != nil else {
                if let token = loginShellClaudeToken() { return .success(token) }
                return .failure(.claudeKeychainUnavailable)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if let token = loginShellClaudeToken() { return .success(token) }
                return .failure(.claudeKeychain(process.terminationStatus))
            }
            data = output.fileHandleForReading.readDataToEndOfFile()
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return .failure(.invalidClaudeCredentials) }
        return .success(token)
    }

    // The menu-bar app launched via LaunchAgent does not inherit shell
    // exports, so CLAUDE_CODE_OAUTH_TOKEN set in ~/.zshrc must be resolved
    // through an interactive login shell.
    private static func loginShellClaudeToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "printf 'ELINK_TOKEN<%s>' \"$CLAUDE_CODE_OAUTH_TOKEN\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) else { return nil }
        return claudeTokenFromShellOutput(text)
    }

    static func claudeTokenFromShellOutput(_ text: String) -> String? {
        guard let start = text.range(of: "ELINK_TOKEN<"),
              let end = text.range(of: ">", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let token = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func codexCredentials() -> Result<(token: String, account: String?), CredentialError> {
        let file = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: file) else {
            return .failure(.missingCodexFile)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else { return .failure(.invalidCodexCredentials) }
        var account = tokens["account_id"] as? String
        if account == nil, let jwt = tokens["id_token"] as? String { account = accountID(jwt: jwt) }
        return .success((token, account))
    }

    static func accountID(jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    private static func isoWindow(_ value: Any?) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["utilization"] as? NSNumber)?.doubleValue
        let resetAt = (object["resets_at"] as? String).flatMap(Self.isoDate)
        return UsageWindow(
            percent: percent,
            resetMinutes: resetAt.flatMap { Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970) },
            resetAt: resetAt
        ).discardingIfExpired()
    }

    private static func epochWindow(_ value: Any?) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["used_percent"] as? NSNumber)?.doubleValue
        let resetAt = (object["reset_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return UsageWindow(
            percent: percent,
            resetMinutes: resetAt.flatMap { Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970) },
            resetAt: resetAt
        ).discardingIfExpired()
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func request(_ request: URLRequest) -> (Data, Int)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse { result = (data, response.statusCode) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}

extension NSLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
