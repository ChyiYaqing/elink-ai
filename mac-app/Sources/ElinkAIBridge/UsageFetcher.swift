import Foundation

final class UsageFetcher {
    private let lock = NSLock()
    private let cacheStore: UsageStore?
    private var storedClaude = ProviderUsage()
    private var storedCodex = ProviderUsage()
    private var fetching = false
    private var pendingForcedRefresh = false
    private var nextAllowed = Date.distantPast
    private var lastLogSummary = ""
    private var timer: Timer?
    private var refreshCompletions: [() -> Void] = []
    /// 本轮 fetch 中服务端要求的最长等待。只在 refresh 的串行 async 块里写，
    /// 在同一块末尾读出并清空，因此不需要额外加锁。
    private var pendingRetryAfter: TimeInterval?
    private let claudeTokenProvider: () -> Result<String, CredentialError>
    private let requestHandler: (URLRequest) -> HTTPOutcome?
    var onUpdate: (() -> Void)?

    var claude: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedClaude) } }
    var codex: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedCodex) } }

    init(cacheStore: UsageStore? = nil,
         claudeTokenProvider: (() -> Result<String, CredentialError>)? = nil,
         requestHandler: ((URLRequest) -> HTTPOutcome?)? = nil) {
        self.cacheStore = cacheStore
        self.claudeTokenProvider = claudeTokenProvider ?? Self.claudeToken
        self.requestHandler = requestHandler ?? Self.request
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
                if force { pendingForcedRefresh = true }
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
        performRefresh()
    }

    /// `force` 在请求进行中到达时不能只挂一个 completion：那一轮已经捕获了旧
    /// 凭据。保持 fetching=true 串行补跑一轮，直到最后一次强制刷新之后再完成
    /// 所有等待者，避免旧 token 的 401/429 冒充新 token 的结果。
    private func performRefresh() {
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
            let result = self.lock.holding { () -> (completions: [() -> Void], refreshAgain: Bool) in
                self.storedClaude = Self.keepLastGood(old: self.storedClaude, new: claude)
                self.storedCodex = Self.keepLastGood(old: self.storedCodex, new: codex)
                let rateLimited = claude.error?.contains("429") == true || codex.error?.contains("429") == true
                self.nextAllowed = Date().addingTimeInterval(
                    Self.backoffInterval(retryAfter: self.pendingRetryAfter, rateLimited: rateLimited))
                self.pendingRetryAfter = nil
                let summary = "usage claude=\(Self.describe(claude)) codex=\(Self.describe(codex))"
                if summary != self.lastLogSummary {
                    self.lastLogSummary = summary
                    if claude.error != nil || codex.error != nil {
                        Log.warning(summary, category: "usage")
                    } else {
                        Log.info(summary, category: "usage")
                    }
                }
                if self.pendingForcedRefresh {
                    self.pendingForcedRefresh = false
                    return ([], true)
                }
                self.fetching = false
                let values = self.refreshCompletions
                self.refreshCompletions.removeAll()
                return (values, false)
            }
            DispatchQueue.main.async {
                self.onUpdate?()
                if result.refreshAgain {
                    self.performRefresh()
                } else {
                    result.completions.forEach { $0() }
                }
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
        // 请求失败回退到 statusline 缓存时，不能让更旧的缓存覆盖内存里更新鲜的配额
        if current.isCached, hadGoodValue,
           let newFetched = current.fetchedAt, let oldFetched = old.fetchedAt,
           oldFetched > newFetched {
            var retained = old
            retained.primary = previousPrimary
            retained.weekly = previousWeekly
            retained.error = new.error
            retained.isCached = true
            return retained
        }
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

    /// 两家 provider 同轮都被限流时取更长的那个，避免为了迁就一家而顶着
    /// 另一家的窗口重试。
    private func noteRetryAfter(_ outcome: HTTPOutcome) {
        guard let seconds = outcome.retryAfter else { return }
        pendingRetryAfter = max(pendingRetryAfter ?? 0, seconds)
    }

    private func fetchClaude() -> ProviderUsage {
        let token: String
        switch claudeTokenProvider() {
        case let .success(value):
            token = value
        case let .failure(error):
            if var cached = Self.cachedClaudeUsage() {
                cached.error = tr("\(error.localizedDescription)，显示状态栏缓存",
                                  "\(error.localizedDescription) — showing status bar cache")
                return cached
            }
            return ProviderUsage(error: error.localizedDescription)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let outcome = requestHandler(request) else {
            return Self.claudeFallback(error: tr("Claude 用量请求失败", "Claude usage request failed"))
        }
        guard outcome.status == 200 else {
            noteRetryAfter(outcome)
            return Self.claudeFallback(
                error: tr("Claude 用量 HTTP \(outcome.status)", "Claude usage HTTP \(outcome.status)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            return Self.claudeFallback(error: tr("Claude 用量响应解析失败", "Failed to parse Claude usage response"))
        }
        let primary = Self.isoWindow(json["five_hour"])
        let weekly = Self.isoWindow(json["seven_day"])
        return ProviderUsage(primary: primary, weekly: weekly, fetchedAt: Date())
    }

    enum ClaudeTokenValidationError: LocalizedError, Equatable {
        case rejected
        case temporarilyLimited
        case requestFailed
        case invalidResponse
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .rejected:
                return tr("Claude 拒绝了这个 token，请重新运行 claude setup-token",
                          "Claude rejected this token; run claude setup-token again")
            case .temporarilyLimited:
                return tr("Claude 用量接口暂时受限，请稍后重试",
                          "Claude usage is temporarily limited; try again later")
            case .requestFailed:
                return tr("无法连接 Claude 验证 token", "Could not reach Claude to validate the token")
            case .invalidResponse:
                return tr("Claude 验证响应格式无效", "Claude returned an invalid validation response")
            case let .http(status):
                return tr("Claude token 验证 HTTP \(status)", "Claude token validation HTTP \(status)")
            }
        }
    }

    /// 保存前先用候选 token 请求一次用量。只有服务端明确返回成功才允许覆盖
    /// Keychain 里的旧值；网络错误、限流和 401/403 都保留旧凭据。
    static func validateClaudeToken(_ token: String) -> Result<ProviderUsage, ClaudeTokenValidationError> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return claudeTokenValidation(outcome: Self.request(request))
    }

    static func claudeTokenValidation(
        outcome: HTTPOutcome?, now: Date = Date()
    ) -> Result<ProviderUsage, ClaudeTokenValidationError> {
        guard let outcome else { return .failure(.requestFailed) }
        if outcome.status == 401 || outcome.status == 403 { return .failure(.rejected) }
        if outcome.status == 429 { return .failure(.temporarilyLimited) }
        guard outcome.status == 200 else { return .failure(.http(outcome.status)) }
        guard let json = try? JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            return .failure(.invalidResponse)
        }
        return .success(ProviderUsage(
            primary: isoWindow(json["five_hour"]),
            weekly: isoWindow(json["seven_day"]),
            fetchedAt: now
        ))
    }

    func acceptValidatedClaudeUsage(_ usage: ProviderUsage) {
        cacheStore?.cacheUsage(provider: "claude", usage: usage)
        lock.holding {
            storedClaude = usage
            // 验证请求与周期刷新可能并发。旧凭据请求若仍在飞行，必须在它落地后
            // 再补一轮新凭据请求，否则旧 401/429 会覆盖刚验证成功的状态。
            if fetching { pendingForcedRefresh = true }
        }
        if Thread.isMainThread {
            onUpdate?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
        }
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
        guard let outcome = requestHandler(request) else {
            return ProviderUsage(error: tr("Codex 用量请求失败", "Codex usage request failed"))
        }
        let data = outcome.data
        let status = outcome.status
        guard (200...299).contains(status) else {
            noteRetryAfter(outcome)
            let error = status == 401 || status == 403
                ? tr("Codex 凭据过期，请运行 codex 重新登录",
                     "Codex credentials expired — run codex to sign in again")
                : status == 429 ? tr("Codex 用量 HTTP 429，稍后自动重试",
                                     "Codex usage HTTP 429 — will retry automatically")
                : tr("Codex 用量 HTTP \(status)", "Codex usage HTTP \(status)")
            return ProviderUsage(error: error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else {
            return ProviderUsage(error: tr("Codex 用量响应解析失败", "Failed to parse Codex usage response"))
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

    enum CredentialError: LocalizedError, Equatable {
        case elinkClaudeCredential(String)
        case claudeKeychainUnavailable
        case claudeKeychain(Int32)
        case invalidClaudeCredentials
        case expiredClaudeCredentials
        case missingCodexFile
        case invalidCodexCredentials

        var errorDescription: String? {
            switch self {
            case let .elinkClaudeCredential(message):
                return tr("Elink Claude 凭据不可用：\(message)",
                          "Elink Claude credential unavailable: \(message)")
            case .claudeKeychainUnavailable:
                return tr("无法调用 macOS Keychain 读取 Claude 凭据",
                          "Cannot access macOS Keychain to read Claude credentials")
            case let .claudeKeychain(status):
                return tr("Keychain 中未找到或无法访问 Claude 凭据（security \(status)）",
                          "Claude credentials not found or inaccessible in Keychain (security \(status))")
            case .invalidClaudeCredentials:
                return tr("Claude 凭据格式无效，请运行 claude 重新登录",
                          "Invalid Claude credentials — run claude to sign in again")
            case .expiredClaudeCredentials:
                return tr("Claude 凭据已过期，请运行 claude 重新登录",
                          "Claude credentials expired — run claude to sign in again")
            case .missingCodexFile:
                return tr("未找到 ~/.codex/auth.json，请运行 codex 重新登录",
                          "~/.codex/auth.json not found — run codex to sign in again")
            case .invalidCodexCredentials:
                return tr("Codex 凭据格式无效，请运行 codex 重新登录",
                          "Invalid Codex credentials — run codex to sign in again")
            }
        }
    }

    private static func claudeToken() -> Result<String, CredentialError> {
        let elinkToken: String?
        do {
            elinkToken = try ElinkClaudeTokenStore.shared.token()
        } catch {
            return .failure(.elinkClaudeCredential(error.localizedDescription))
        }
        let environmentToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]
        // ~/.claude/.credentials.json 可能是过期的遗留文件，而 Claude Code 在
        // macOS 上刷新的是 Keychain 条目。只有文件里的 token 仍然有效时才用它，
        // 否则继续回落到 Keychain，否则用量接口会一直 401 直到被限流。
        let file = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        return claudeToken(
            elinkToken: elinkToken,
            environmentToken: environmentToken,
            fileData: FileManager.default.contents(atPath: file),
            keychainData: claudeKeychainData,
            shellToken: loginShellClaudeToken
        )
    }

    static func claudeToken(
        elinkToken: String? = nil,
        environmentToken: String?,
        fileData: Data?,
        keychainData: () -> Result<Data, CredentialError>,
        shellToken: () -> String?
    ) -> Result<String, CredentialError> {
        if let elinkToken, !elinkToken.isEmpty {
            return .success(elinkToken)
        }
        if let environmentToken, !environmentToken.isEmpty {
            return .success(environmentToken)
        }

        var sawExpiredCredential = false
        func usableToken(from data: Data?) -> String? {
            guard let data, let credential = claudeCredential(data) else { return nil }
            guard credential.isValid() else {
                sawExpiredCredential = true
                return nil
            }
            return credential.token
        }

        if let token = usableToken(from: fileData) { return .success(token) }

        switch keychainData() {
        case let .success(data):
            if let token = usableToken(from: data) { return .success(token) }
        case let .failure(error):
            if let token = shellToken() { return .success(token) }
            return .failure(sawExpiredCredential ? .expiredClaudeCredentials : error)
        }

        // 已知过期的 token 不值得再发一次请求：401 之后的重试会被限流，而 429
        // 的退避最长能拖到一小时，面板只能一直显示 statusline 缓存。
        if let token = shellToken() { return .success(token) }
        return .failure(sawExpiredCredential ? .expiredClaudeCredentials : .invalidClaudeCredentials)
    }

    private static func claudeKeychainData() -> Result<Data, CredentialError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return .failure(.claudeKeychainUnavailable)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(.claudeKeychain(process.terminationStatus))
        }
        return .success(output.fileHandleForReading.readDataToEndOfFile())
    }

    struct ClaudeCredential {
        let token: String
        let expiresAt: Date?

        /// 缺少 `expiresAt` 时视为有效——旧格式没有该字段，不能因此丢弃唯一的
        /// 凭据。预留 60 秒余量，避免卡在过期边界上白费一轮请求。
        func isValid(at now: Date = Date()) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSince(now) > 60
        }
    }

    static func claudeCredential(_ data: Data) -> ClaudeCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        let expiresAt: Date?
        if let rawExpiresAt = oauth["expiresAt"] {
            guard let milliseconds = rawExpiresAt as? NSNumber else { return nil }
            expiresAt = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        } else {
            expiresAt = nil
        }
        return ClaudeCredential(token: token, expiresAt: expiresAt)
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

    struct HTTPOutcome {
        let data: Data
        let status: Int
        let retryAfter: TimeInterval?
    }

    private static func request(_ request: URLRequest) -> HTTPOutcome? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: HTTPOutcome?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse {
                result = HTTPOutcome(
                    data: data,
                    status: response.statusCode,
                    retryAfter: retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"))
                )
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// RFC 7231 允许 `Retry-After` 是秒数或 HTTP-date，两种都接受。
    /// 解析不出来返回 nil，退回调用方的默认退避，绝不当作 0 立即重试。
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) { return seconds > 0 ? seconds : nil }
        guard let date = httpDate.date(from: raw) else { return nil }
        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }

    /// 服务端说了等多久就等多久。此前这里硬编码 300 秒，而实测响应头是
    /// `Retry-After: 414` —— 配合 120 秒 timer 得到的 360 秒重试间隔永远落在
    /// 限流窗口内，跨越两天 25 次请求无一成功，且失败本身又把窗口顺延，
    /// 靠自己走不出来。加 5 秒余量避开边界抖动；封顶 1 小时，免得服务端给出
    /// 一个超长值把刷新彻底饿死。
    static func backoffInterval(retryAfter: TimeInterval?, rateLimited: Bool) -> TimeInterval {
        guard let retryAfter else { return rateLimited ? 300 : 60 }
        return min(max(retryAfter + 5, 60), 3600)
    }
}

extension NSLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
