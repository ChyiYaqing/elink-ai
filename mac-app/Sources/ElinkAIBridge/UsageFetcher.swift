import Foundation

final class UsageFetcher {
    private let lock = NSLock()
    private var storedClaude = ProviderUsage()
    private var storedCodex = ProviderUsage()
    private var fetching = false
    private var nextAllowed = Date.distantPast
    private var timer: Timer?
    var onUpdate: (() -> Void)?

    var claude: ProviderUsage { lock.holding { storedClaude } }
    var codex: ProviderUsage { lock.holding { storedCodex } }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let shouldStart = lock.holding { () -> Bool in
            guard !fetching, Date() >= nextAllowed else { return false }
            fetching = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let claude = self.fetchClaude()
            let codex = self.fetchCodex()
            self.lock.holding {
                self.storedClaude = Self.keepLastGood(old: self.storedClaude, new: claude)
                self.storedCodex = Self.keepLastGood(old: self.storedCodex, new: codex)
                self.fetching = false
                self.nextAllowed = Date().addingTimeInterval(claude.error?.contains("429") == true ? 300 : 60)
            }
            DispatchQueue.main.async { self.onUpdate?() }
        }
    }

    private static func keepLastGood(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        guard new.primary.percent == nil, new.weekly.percent == nil, old.primary.percent != nil else { return new }
        var retained = old
        retained.error = new.error
        return retained
    }

    private func fetchClaude() -> ProviderUsage {
        guard let token = Self.claudeToken() else {
            return Self.cachedClaudeUsage()
                ?? ProviderUsage(error: "未找到 Claude 登录凭据或可用的状态栏缓存")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, status) = Self.request(request) else {
            return Self.cachedClaudeUsage() ?? ProviderUsage(error: "Claude 用量请求失败")
        }
        guard status == 200 else {
            return Self.cachedClaudeUsage() ?? ProviderUsage(error: "Claude 用量 HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.cachedClaudeUsage() ?? ProviderUsage(error: "Claude 用量响应解析失败")
        }
        let primary = Self.isoWindow(json["five_hour"])
        let weekly = Self.isoWindow(json["seven_day"])
        return ProviderUsage(primary: primary, weekly: weekly, fetchedAt: Date())
    }

    private static func cachedClaudeUsage(now: Date = Date()) -> ProviderUsage? {
        let file = URL(fileURLWithPath: ("~/.cache/statusline/last.json" as NSString).expandingTildeInPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) >= 0,
              now.timeIntervalSince(modified) <= 6 * 60 * 60,
              let data = FileManager.default.contents(atPath: file.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claudeStatuslineUsage(json, fetchedAt: modified)
    }

    static func claudeStatuslineUsage(_ json: [String: Any], fetchedAt: Date) -> ProviderUsage? {
        guard let limits = json["rate_limits"] as? [String: Any] else { return nil }
        let primary = statuslineWindow(limits["five_hour"])
        let weekly = statuslineWindow(limits["seven_day"])
        guard primary.percent != nil || weekly.percent != nil else { return nil }
        return ProviderUsage(primary: primary, weekly: weekly, fetchedAt: fetchedAt)
    }

    private static func statuslineWindow(_ value: Any?) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["used_percentage"] as? NSNumber)?.doubleValue
        let reset = (object["resets_at"] as? NSNumber)?.doubleValue
        return UsageWindow(
            percent: percent,
            resetMinutes: reset.map { max(0, Int(($0 - Date().timeIntervalSince1970) / 60)) }
        )
    }

    private func fetchCodex() -> ProviderUsage {
        guard let credentials = Self.codexCredentials() else {
            return ProviderUsage(error: "未找到 Codex 登录凭据")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = credentials.account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        guard let (data, status) = Self.request(request) else {
            return ProviderUsage(error: "Codex 用量请求失败")
        }
        guard (200...299).contains(status) else { return ProviderUsage(error: "Codex 用量 HTTP \(status)") }
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

    private static func claudeToken() -> String? {
        let file = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        var data = FileManager.default.contents(atPath: file)
        if data == nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            data = output.fileHandleForReading.readDataToEndOfFile()
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    private static func codexCredentials() -> (token: String, account: String?)? {
        let file = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        var account = tokens["account_id"] as? String
        if account == nil, let jwt = tokens["id_token"] as? String { account = accountID(jwt: jwt) }
        return (token, account)
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
        let reset = (object["resets_at"] as? String).flatMap(Self.isoDate)
        return UsageWindow(percent: percent, resetMinutes: reset.map { max(0, Int($0.timeIntervalSinceNow / 60)) })
    }

    private static func epochWindow(_ value: Any?) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["used_percent"] as? NSNumber)?.doubleValue
        let reset = (object["reset_at"] as? NSNumber)?.doubleValue
        return UsageWindow(percent: percent, resetMinutes: reset.map { max(0, Int(($0 - Date().timeIntervalSince1970) / 60)) })
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
