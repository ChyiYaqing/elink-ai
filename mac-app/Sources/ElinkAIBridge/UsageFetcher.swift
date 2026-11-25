import Foundation

final class UsageFetcher {
    private let lock = NSLock()
    private let cacheStore: UsageStore?
    private var storedClaude = ProviderUsage()
    private var storedCodex = ProviderUsage()
    private var storedGemini = ProviderUsage()
    private var geminiAccessTokenCache: (token: String, expiresAt: Date)?
    private var geminiProjectIDCache: String?
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
    /// 入参是「这轮刷新是否由用户主动触发」，返回是否观察到凭据续上。
    private let claudeRefresher: (Bool) -> Bool
    private let geminiCredentialsProvider: () -> Result<GeminiCredentials, CredentialError>?
    private let requestHandler: (URLRequest) -> HTTPOutcome?
    var onUpdate: (() -> Void)?

    var claude: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedClaude) } }
    var codex: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedCodex) } }
    var gemini: ProviderUsage { lock.holding { Self.discardingExpiredWindows(storedGemini) } }

    init(cacheStore: UsageStore? = nil,
         claudeTokenProvider: (() -> Result<String, CredentialError>)? = nil,
         claudeRefresher: ((Bool) -> Bool)? = nil,
         geminiCredentialsProvider: (() -> Result<GeminiCredentials, CredentialError>?)? = nil,
         requestHandler: ((URLRequest) -> HTTPOutcome?)? = nil) {
        self.cacheStore = cacheStore
        self.claudeTokenProvider = claudeTokenProvider ?? Self.claudeToken
        self.claudeRefresher = claudeRefresher ?? { userInitiated in
            ClaudeDelegatedRefresh.attempt(
                userInitiated: userInitiated,
                credentialIsUsable: { Self.claudeKeychainCredentialIsValid() }
            )
        }
        self.geminiCredentialsProvider = geminiCredentialsProvider ?? Self.defaultGeminiCredentialsFromDisk
        self.requestHandler = requestHandler ?? Self.request
        storedClaude = cacheStore?.cachedUsage(provider: "claude") ?? ProviderUsage()
        storedCodex = cacheStore?.cachedUsage(provider: "codex") ?? ProviderUsage()
        storedGemini = cacheStore?.cachedUsage(provider: "gemini") ?? ProviderUsage()
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
        performRefresh(force: force)
    }

    /// `force` 在请求进行中到达时不能只挂一个 completion：那一轮已经捕获了旧
    /// 凭据。保持 fetching=true 串行补跑一轮，直到最后一次强制刷新之后再完成
    /// 所有等待者，避免旧 token 的 401/429 冒充新 token 的结果。
    private func performRefresh(force: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let claude = self.fetchClaude(userInitiated: force)
            let codex = self.fetchCodex()
            let gemini = self.fetchGemini()
            if claude.error == nil || claude.primary.percent != nil || claude.weekly.percent != nil {
                self.cacheStore?.cacheUsage(provider: "claude", usage: claude)
            }
            if codex.error == nil || codex.primary.percent != nil || codex.weekly.percent != nil {
                self.cacheStore?.cacheUsage(provider: "codex", usage: codex)
            }
            if gemini.error == nil || gemini.primary.percent != nil || gemini.weekly.percent != nil {
                self.cacheStore?.cacheUsage(provider: "gemini", usage: gemini)
            }
            let result = self.lock.holding { () -> (completions: [() -> Void], refreshAgain: Bool) in
                self.storedClaude = Self.keepLastGood(old: self.storedClaude, new: claude)
                self.storedCodex = Self.keepLastGood(old: self.storedCodex, new: codex)
                self.storedGemini = Self.keepLastGood(old: self.storedGemini, new: gemini)
                let rateLimited = claude.error?.contains("429") == true
                    || codex.error?.contains("429") == true
                    || gemini.error?.contains("429") == true
                self.nextAllowed = Date().addingTimeInterval(
                    Self.backoffInterval(retryAfter: self.pendingRetryAfter, rateLimited: rateLimited))
                self.pendingRetryAfter = nil
                let summary = "usage claude=\(Self.describe(claude)) codex=\(Self.describe(codex)) gemini=\(Self.describe(gemini))"
                if summary != self.lastLogSummary {
                    self.lastLogSummary = summary
                    if claude.error != nil || codex.error != nil || gemini.error != nil {
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
                    // 补跑的这一轮就是那次强制刷新本身。
                    self.performRefresh(force: true)
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
        // statusline 缓存里没有额外用量和作用域限额，它落地时不该把上一轮真正
        // 取到的那份抹掉——卡片此时已经标了「缓存」，整块消失只会让人以为
        // 额度池被关了。
        if current.isCached {
            if current.extraUsage == nil { current.extraUsage = old.extraUsage }
            if current.creditBalance == nil { current.creditBalance = old.creditBalance }
            if current.scopedLimits.isEmpty { current.scopedLimits = old.scopedLimits }
        }
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
        value.scopedLimits = value.scopedLimits
            .map { $0.discardingIfExpired(at: now) }
            .filter { $0.window.percent != nil }
        return value
    }

    /// 两家 provider 同轮都被限流时取更长的那个，避免为了迁就一家而顶着
    /// 另一家的窗口重试。
    private func noteRetryAfter(_ outcome: HTTPOutcome) {
        guard let seconds = outcome.retryAfter else { return }
        pendingRetryAfter = max(pendingRetryAfter ?? 0, seconds)
    }

    /// Claude Code 只在自己发请求时才续期，空闲会话不会：凭据过期时先让它自己
    /// 刷新一次，再重新读。观察不到续上就别白发一次注定 401 的请求——401 之后的
    /// 重试会被限流，429 的退避最长能拖到一小时。
    private func claudeTokenRenewingIfExpired(
        userInitiated: Bool
    ) -> Result<String, CredentialError> {
        let result = claudeTokenProvider()
        guard case let .failure(error) = result,
              error == .expiredClaudeCredentials,
              claudeRefresher(userInitiated) else { return result }
        return claudeTokenProvider()
    }

    private func fetchClaude(userInitiated: Bool) -> ProviderUsage {
        let token: String
        switch claudeTokenRenewingIfExpired(userInitiated: userInitiated) {
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
        guard let outcome = requestHandler(Self.claudeUsageRequest(token: token)) else {
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
        return Self.claudeUsage(json, fetchedAt: Date())
    }

    /// 用量端点是 Claude Code 的私有接口，只认它自己的那套请求头。
    ///
    /// `anthropic-beta` 之外还要带 claude-code 的 User-Agent：不带等于主动告诉
    /// 服务端「这不是 Claude Code」，而这个端点没有任何理由优待一个陌生客户端。
    static func claudeUsageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 取本机装的那份 Claude Code 版本号，取不到就兜一个已知能用的值。
    /// 版本号旧一点无所谓，请求里没有 UA 才是问题。
    static let claudeCodeUserAgent = "claude-code/\(claudeCodeVersion() ?? "2.1.0")"

    static let claudeBinaryCandidates = [
        "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ]

    /// 原生安装器把可执行文件软链到 `.../versions/<版本号>`，顺着链接找回版本号即可。
    /// 其他安装方式找不到就返回 nil，交给上面的兜底值——为了一个请求头去跑
    /// `claude --version`（每次都要起一个进程）不划算。
    static func claudeCodeVersion(
        candidates: [String] = UsageFetcher.claudeBinaryCandidates,
        resolve: (String) -> String? = { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    ) -> String? {
        for candidate in candidates {
            guard let resolved = resolve((candidate as NSString).expandingTildeInPath) else { continue }
            if let version = URL(fileURLWithPath: resolved).pathComponents
                .reversed().first(where: isVersionComponent) {
                return version
            }
        }
        return nil
    }

    private static func isVersionComponent(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.prefix(3).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func claudeUsage(_ json: [String: Any], fetchedAt: Date,
                            now: Date = Date()) -> ProviderUsage {
        ProviderUsage(
            primary: isoWindow(json["five_hour"], now: now),
            weekly: isoWindow(json["seven_day"], now: now),
            scopedLimits: claudeScopedLimits(json, now: now),
            extraUsage: claudeExtraUsage(json["extra_usage"]),
            fetchedAt: fetchedAt
        )
    }

    /// `extra_usage` 的金额是最小货币单位，`decimal_places` 说明缩几位。
    /// 关掉的池子返回 nil：没有额度可用时展示一条「0 / 0」只是噪声。
    static func claudeExtraUsage(_ value: Any?) -> ExtraUsage? {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let used = (object["used_credits"] as? NSNumber)?.doubleValue,
              let limit = (object["monthly_limit"] as? NSNumber)?.doubleValue,
              limit > 0 else { return nil }
        let places = (object["decimal_places"] as? NSNumber)?.intValue ?? 2
        let scale = pow(10.0, Double(min(max(places, 0), 6)))
        let percent = (object["utilization"] as? NSNumber)?.doubleValue ?? used / limit * 100
        let currency = (object["currency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ExtraUsage(
            used: used / scale,
            limit: limit / scale,
            percent: min(100, max(0, percent)),
            unit: currency.isEmpty ? "USD" : currency
        )
    }

    /// 模型作用域的周限额。新版接口放在 `limits` 数组里（条目带 `scope.model`），
    /// 老账号仍然是平铺的 `seven_day_opus` / `seven_day_sonnet`，两种都读。
    ///
    /// 不按 `is_active` 过滤：实测正在生效的限额也会报 false，拿它当开关会把
    /// 真实限额整条藏掉。
    static func claudeScopedLimits(_ json: [String: Any], now: Date = Date()) -> [ScopedLimit] {
        var result: [ScopedLimit] = []
        var seen: Set<String> = []
        for entry in json["limits"] as? [[String: Any]] ?? [] {
            let group = ((entry["group"] as? String) ?? (entry["kind"] as? String) ?? "").lowercased()
            guard group.contains("weekly"),
                  let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any] else {
                continue
            }
            let identifier = (model["id"] as? String) ?? ""
            let title = (model["display_name"] as? String) ?? identifier
            guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { continue }
            let resetAt = (entry["resets_at"] as? String).flatMap(isoDate)
            let window = UsageWindow(
                percent: (entry["percent"] as? NSNumber)?.doubleValue,
                resetMinutes: resetAt.flatMap {
                    remainingMinutes(untilEpoch: $0.timeIntervalSince1970, now: now)
                },
                resetAt: resetAt
            ).discardingIfExpired(at: now)
            guard window.percent != nil else { continue }
            result.append(ScopedLimit(id: identifier.isEmpty ? title : identifier,
                                      title: title, window: window))
        }
        for (key, title) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            guard seen.insert(title.lowercased()).inserted else { continue }
            let window = isoWindow(json[key], now: now)
            guard window.percent != nil else { continue }
            result.append(ScopedLimit(id: key, title: title, window: window))
        }
        return result
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
        claudeTokenValidation(outcome: Self.request(claudeUsageRequest(token: token)))
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
        return .success(claudeUsage(json, fetchedAt: now, now: now))
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
              json["rate_limit"] is [String: Any] else {
            return ProviderUsage(error: tr("Codex 用量响应解析失败", "Failed to parse Codex usage response"))
        }
        return Self.codexUsage(json, fetchedAt: Date())
    }

    static func codexUsage(_ json: [String: Any], fetchedAt: Date,
                           now: Date = Date()) -> ProviderUsage {
        let windows = codexWindows(json["rate_limit"] as? [String: Any] ?? [:], now: now)
        return ProviderUsage(
            primary: windows.primary,
            weekly: windows.weekly,
            scopedLimits: codexScopedLimits(json, now: now),
            extraUsage: codexExtraUsage(json),
            creditBalance: codexCreditBalance(json),
            fetchedAt: fetchedAt
        )
    }

    /// Codex 的按量额度（spend control）。三处都可能放它，按这个顺序取第一个
    /// 能用的：响应根、`rate_limit` 里、`spend_control` 里。
    ///
    /// 单位是**积分**不是货币——OpenAI 的支出控制按 credit 计，所以这里标
    /// `credits`，显示端据此不加货币符号。
    static func codexExtraUsage(_ json: [String: Any]) -> ExtraUsage? {
        let candidates = [
            json["individual_limit"],
            (json["rate_limit"] as? [String: Any])?["individual_limit"],
            (json["spend_control"] as? [String: Any])?["individual_limit"],
        ]
        guard let object = candidates.compactMap({ $0 as? [String: Any] }).first,
              let limit = flexibleDouble(object["limit"]), limit > 0 else { return nil }
        // `used` 缺席时从剩余百分比反推：接口两种都给过，缺一个不该让整块消失
        let remaining = flexibleDouble(object["remaining_percent"])
            ?? flexibleDouble(object["remainingPercent"])
        let used = flexibleDouble(object["used"])
            ?? remaining.map { limit * min(100, max(0, 100 - $0)) / 100 }
            ?? 0
        let percent = remaining.map { 100 - $0 } ?? used / limit * 100
        return ExtraUsage(used: used, limit: limit,
                          percent: min(100, max(0, percent)),
                          unit: ExtraUsage.creditsUnit)
    }

    /// 积分余额。只有接口说这个账号确实有积分池时才返回——给每个 Plus 用户
    /// 挂一行「余额 0」是噪声。`balance` 实测是字符串 `"0"`，数字也见过，两种都收。
    static func codexCreditBalance(_ json: [String: Any]) -> Double? {
        guard let credits = json["credits"] as? [String: Any],
              credits["has_credits"] as? Bool == true else { return nil }
        return flexibleDouble(credits["balance"])
    }

    /// 同一个字段在不同账号上见过数字和字符串两种写法，都接受；接不住返回 nil，
    /// 而不是当成 0——一个凭空的 0 会被读成「额度用光了」。
    static func flexibleDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// `additional_rate_limits` 是与 primary/secondary 并列、只对某个模型生效的
    /// 额外限额（例如 Codex Spark）。落到与 Claude 同一个 `scopedLimits` 字段：
    /// 两家问的是同一个问题——总额度还够，但这个模型自己的那份还剩多少。
    ///
    /// 一条限额可能同时有 5 小时和周两个窗口，各占一行；只有一个窗口就只出一行。
    static func codexScopedLimits(_ json: [String: Any], now: Date = Date()) -> [ScopedLimit] {
        var result: [ScopedLimit] = []
        var seen: Set<String> = []
        for entry in json["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = ((entry["limit_name"] as? String) ?? (entry["metered_feature"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let windows = codexWindows(entry["rate_limit"] as? [String: Any] ?? [:], now: now)
            for (suffix, window) in [("", windows.primary),
                                     (tr(" 周", " weekly"), windows.weekly)] {
                guard window.percent != nil else { continue }
                let title = name + suffix
                guard seen.insert(title.lowercased()).inserted else { continue }
                result.append(ScopedLimit(id: title, title: title, window: window))
            }
        }
        return result
    }

    static func codexWindows(_ limits: [String: Any],
                             now: Date = Date()) -> (primary: UsageWindow, weekly: UsageWindow) {
        var primary = UsageWindow()
        var weekly = UsageWindow()
        let values = [limits["primary_window"], limits["secondary_window"]]

        for (index, value) in values.enumerated() {
            guard let object = value as? [String: Any] else { continue }
            let window = epochWindow(object, now: now)
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
        case expiredCodexCredentials
        case missingGeminiFile
        case invalidGeminiCredentials
        case expiredGeminiCredentials

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
            // 走到这条消息时委托刷新已经试过一次了，而且 refresh token 通常还有
            // 好几周有效期——「重新登录」是多余的动作。
            case .expiredClaudeCredentials:
                return tr("Claude 凭据已过期且自动续期失败，请运行一次 claude",
                          "Claude credentials expired; auto-renew failed — run claude once")
            case .missingCodexFile:
                return tr("未找到 ~/.codex/auth.json，请运行 codex 重新登录",
                          "~/.codex/auth.json not found — run codex to sign in again")
            case .invalidCodexCredentials:
                return tr("Codex 凭据格式无效，请运行 codex 重新登录",
                          "Invalid Codex credentials — run codex to sign in again")
            case .expiredCodexCredentials:
                return tr("Codex 凭据已过期，请运行 codex 重新登录",
                          "Codex credentials expired — run codex to sign in again")
            case .missingGeminiFile:
                return tr("未找到 ~/.gemini/oauth_creds.json，请运行 gemini 登录",
                          "~/.gemini/oauth_creds.json not found — run gemini to sign in")
            case .invalidGeminiCredentials:
                return tr("Gemini 凭据格式无效，请运行 gemini 重新登录",
                          "Invalid Gemini credentials — run gemini to sign in again")
            case .expiredGeminiCredentials:
                return tr("Gemini 凭据已过期且自动续期失败，请运行 gemini 重新登录",
                          "Gemini credentials expired; auto-renew failed — run gemini to sign in again")
            }
        }
    }

    // MARK: - Gemini Code Assist

    private static let geminiCodeAssistBaseURL =
        "https://cloudcode-pa.googleapis.com/v1internal"

    /// 运行时解析本机 Gemini CLI 的 OAuth desktop client 配置，绝不在仓库中硬编码
    /// 第三方 client secret。优先读环境变量，其次读本机已安装的 `@google/gemini-cli`
    /// bundle；取不到则返回 nil，降级为直接使用现有 `access_token`。
    private static func geminiOAuthClientConfig() -> (id: String, secret: String)? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["GEMINI_OAUTH_CLIENT_ID"], !id.isEmpty,
           let secret = env["GEMINI_OAUTH_CLIENT_SECRET"], !secret.isEmpty {
            return (id, secret)
        }
        let candidates = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle",
        ]
        let idRegex = try? NSRegularExpression(pattern: #"OAUTH_CLIENT_ID\s*=\s*"([^"]+)""#)
        let secretRegex = try? NSRegularExpression(pattern: #"OAUTH_CLIENT_SECRET\s*=\s*"([^"]+)""#)
        for dir in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in files where name.hasPrefix("chunk-") && name.hasSuffix(".js") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      text.contains("OAUTH_CLIENT_SECRET") else { continue }
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let idMatch = idRegex?.firstMatch(in: text, range: range),
                   let secretMatch = secretRegex?.firstMatch(in: text, range: range),
                   idMatch.numberOfRanges > 1, secretMatch.numberOfRanges > 1 {
                    let id = ns.substring(with: idMatch.range(at: 1))
                    let secret = ns.substring(with: secretMatch.range(at: 1))
                    if !id.isEmpty && !secret.isEmpty { return (id, secret) }
                }
            }
        }
        return nil
    }

    struct GeminiCredentials: Equatable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Date?

        func accessTokenIsValid(at now: Date = Date()) -> Bool {
            guard let accessToken, !accessToken.isEmpty else { return false }
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSince(now) > 60
        }
    }

    static func geminiCredentials(fileData: Data) -> Result<GeminiCredentials, CredentialError> {
        guard let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] else {
            return .failure(.invalidGeminiCredentials)
        }
        let accessToken = (json["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard accessToken != nil || refreshToken != nil else {
            return .failure(.invalidGeminiCredentials)
        }
        var expiresAt: Date?
        if let rawExpiry = (json["expiry_date"] as? NSNumber)?.doubleValue {
            let seconds = rawExpiry > 10_000_000_000 ? rawExpiry / 1000 : rawExpiry
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        return .success(GeminiCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        ))
    }

    /// 返回 nil 表示本机未安装/未配置 Gemini CLI，调用方按「未配置」静默跳过。
    private static func defaultGeminiCredentialsFromDisk() -> Result<GeminiCredentials, CredentialError>? {
        if let envToken = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_ACCESS_TOKEN"],
           !envToken.isEmpty {
            return .success(GeminiCredentials(accessToken: envToken, refreshToken: nil, expiresAt: nil))
        }
        let file = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: file) else {
            return nil
        }
        return Self.geminiCredentials(fileData: data)
    }

    private func resolveGeminiAccessToken(forceRefresh: Bool = false) -> Result<String, CredentialError>? {
        let now = Date()
        if !forceRefresh, let cached = geminiAccessTokenCache,
           cached.expiresAt.timeIntervalSince(now) > 60 {
            return .success(cached.token)
        }
        guard let diskResult = geminiCredentialsProvider() else { return nil }
        switch diskResult {
        case let .failure(error):
            return .failure(error)
        case let .success(creds):
            if !forceRefresh, creds.accessTokenIsValid(at: now), let token = creds.accessToken {
                return .success(token)
            }
            guard let refreshToken = creds.refreshToken else {
                return .failure(.expiredGeminiCredentials)
            }
            guard let refreshed = refreshGeminiOAuthToken(refreshToken: refreshToken) else {
                return .failure(.expiredGeminiCredentials)
            }
            geminiAccessTokenCache = refreshed
            return .success(refreshed.token)
        }
    }

    private func refreshGeminiOAuthToken(refreshToken: String) -> (token: String, expiresAt: Date)? {
        guard let client = Self.geminiOAuthClientConfig() else { return nil }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func formEncode(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let pairs = [
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]
        let body = pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        guard let outcome = requestHandler(request), outcome.status == 200,
              let json = try? JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            return nil
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (token, Date().addingTimeInterval(expiresIn))
    }

    private func resolveGeminiProjectID(token: String) -> String? {
        for key in ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"] {
            if let envProject = ProcessInfo.processInfo.environment[key], !envProject.isEmpty {
                return envProject
            }
        }
        if let cached = geminiProjectIDCache, !cached.isEmpty {
            return cached
        }
        var request = URLRequest(url: URL(string: "\(Self.geminiCodeAssistBaseURL):loadCodeAssist")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let outcome = requestHandler(request), outcome.status == 200,
              let json = try? JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            return nil
        }
        if let project = json["cloudaicompanionProject"] as? String, !project.isEmpty {
            geminiProjectIDCache = project
            return project
        }
        if let projectObj = json["cloudaicompanionProject"] as? [String: Any],
           let id = projectObj["id"] as? String, !id.isEmpty {
            geminiProjectIDCache = id
            return id
        }
        return nil
    }

    private func fetchGemini() -> ProviderUsage {
        // 优先读 Antigravity CLI statusLine 写入的本地缓存：官方文档化路径，
        // 直接包含 gemini-5h / gemini-weekly，且不受旧 Gemini CLI 个人账号 403 限制。
        if let cached = Self.cachedAntigravityGeminiUsage() {
            return cached
        }
        guard let tokenResult = resolveGeminiAccessToken() else {
            return ProviderUsage()
        }
        var token: String
        switch tokenResult {
        case let .success(value):
            token = value
        case let .failure(error):
            return ProviderUsage(error: error.localizedDescription)
        }
        let projectID = resolveGeminiProjectID(token: token)
        var outcome = requestHandler(Self.geminiQuotaRequest(token: token, projectID: projectID))
        if outcome?.status == 401 {
            if let retryResult = resolveGeminiAccessToken(forceRefresh: true) {
                switch retryResult {
                case let .success(refreshed):
                    token = refreshed
                    let retryProjectID = projectID ?? resolveGeminiProjectID(token: token)
                    outcome = requestHandler(Self.geminiQuotaRequest(token: token, projectID: retryProjectID))
                case let .failure(error):
                    return ProviderUsage(error: error.localizedDescription)
                }
            }
        }
        guard let outcome else {
            return ProviderUsage(error: tr("Gemini 用量请求失败", "Gemini usage request failed"))
        }
        if outcome.status == 401 {
            return ProviderUsage(error: CredentialError.expiredGeminiCredentials.localizedDescription)
        }
        guard outcome.status == 200 else {
            noteRetryAfter(outcome)
            return ProviderUsage(
                error: tr("Gemini 用量 HTTP \(outcome.status)", "Gemini usage HTTP \(outcome.status)")
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            return ProviderUsage(error: tr("Gemini 用量响应解析失败", "Failed to parse Gemini usage response"))
        }
        return Self.geminiUsage(json, fetchedAt: Date())
    }

    static var antigravityStatuslinePath: String {
        ("~/.cache/statusline/antigravity.json" as NSString).expandingTildeInPath
    }

    static func cachedAntigravityGeminiUsage(
        path: String = antigravityStatuslinePath,
        now: Date = Date()
    ) -> ProviderUsage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              modified <= now,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let usage = antigravityStatuslineGeminiUsage(json, fetchedAt: modified, now: now)
        guard usage.primary.percent != nil || usage.weekly.percent != nil else { return nil }
        let hasReset = usage.primary.resetAt != nil || usage.weekly.resetAt != nil
        if !hasReset && now.timeIntervalSince(modified) > 6 * 3600 { return nil }
        return usage
    }

    /// 解析 Antigravity CLI `statusLine` 管道输出的 JSON：
    /// `quota` 字典映射 bucket ID（如 `gemini-5h`、`gemini-weekly`）到
    /// `{ remaining_fraction, reset_time, reset_in_seconds }`。
    static func antigravityStatuslineGeminiUsage(
        _ json: [String: Any],
        fetchedAt: Date = Date(),
        now: Date = Date()
    ) -> ProviderUsage {
        guard let quota = json["quota"] as? [String: Any] else { return ProviderUsage() }
        var primaryWindows: [UsageWindow] = []
        var weeklyWindows: [UsageWindow] = []
        var scopedLimits: [ScopedLimit] = []

        for key in quota.keys.sorted() {
            let lower = key.lowercased()
            // 只取 Gemini 相关 bucket（跳过 claude / gpt 等第三方池）
            if lower.contains("claude") || lower.contains("gpt") || lower.contains("openai") {
                continue
            }
            guard let entry = quota[key] as? [String: Any] else { continue }
            if entry["disabled"] as? Bool == true { continue }
            guard let remaining = flexibleDouble(entry["remaining_fraction"])
                ?? flexibleDouble(entry["remainingFraction"]) else { continue }
            let clampedRemaining = min(1.0, max(0.0, remaining))
            let usedPercent = min(100.0, max(0.0, (1.0 - clampedRemaining) * 100.0))

            var resetAt = (entry["reset_time"] as? String).flatMap(Self.isoDate)
                ?? (entry["resetTime"] as? String).flatMap(Self.isoDate)
            let resetInSeconds = flexibleDouble(entry["reset_in_seconds"])
                ?? flexibleDouble(entry["resetInSeconds"])
            if resetAt == nil, let seconds = resetInSeconds, seconds > 0 {
                resetAt = fetchedAt.addingTimeInterval(seconds)
            }
            let window = UsageWindow(
                percent: usedPercent,
                resetMinutes: resetAt.flatMap {
                    Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970, now: now)
                },
                resetAt: resetAt
            ).discardingIfExpired(at: now)
            guard window.percent != nil else { continue }

            let isWeekly: Bool
            if lower.contains("week") || lower.contains("7d") || lower.contains("seven_day") {
                isWeekly = true
            } else if lower.contains("5h") || lower.contains("5_hour") || lower.contains("five_hour") {
                isWeekly = false
            } else if let resetAt {
                isWeekly = resetAt.timeIntervalSince(now) > 26 * 3600
            } else if let seconds = resetInSeconds {
                isWeekly = seconds > 26 * 3600
            } else {
                isWeekly = false
            }

            if isWeekly {
                weeklyWindows.append(window)
            } else {
                primaryWindows.append(window)
            }

            // 特定模型子限额写入 scopedLimits（通用 gemini-5h / gemini-weekly 不重复列出）
            if lower != "gemini-5h" && lower != "gemini-weekly" {
                scopedLimits.append(ScopedLimit(id: key, title: key, window: window))
            }
        }

        func pickWorst(_ windows: [UsageWindow]) -> UsageWindow {
            windows.max { lhs, rhs in
                let lp = lhs.percent ?? -1
                let rp = rhs.percent ?? -1
                if lp != rp { return lp < rp }
                let lr = lhs.resetAt ?? .distantFuture
                let rr = rhs.resetAt ?? .distantFuture
                return lr > rr
            } ?? UsageWindow()
        }

        return ProviderUsage(
            primary: pickWorst(primaryWindows),
            weekly: pickWorst(weeklyWindows),
            scopedLimits: scopedLimits,
            fetchedAt: fetchedAt,
            isCached: false
        )
    }

    static func geminiQuotaRequest(token: String, projectID: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(geminiCodeAssistBaseURL):retrieveUserQuota")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = projectID.map { ["project": $0] } ?? [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 解析 Gemini Code Assist `retrieveUserQuota` 响应。
    ///
    /// 每个 bucket 携带 `modelId`、`remainingFraction`、`resetTime`，可能还带
    /// `window`/`duration`/`limitWindowSeconds`。按窗口时长拆成 5 小时（`primary`）
    /// 与周（`weekly`）两类：显式标了周窗口或 `resetTime - now > 26h` 归入 `weekly`，
    /// 其余归入 `primary`。多模型（Pro / Flash / Flash Lite）的独立额度写入
    /// `scopedLimits`，主窗口取最紧张的那个 bucket；缺少的窗口保持 nil，绝不伪造 0%。
    static func geminiUsage(_ json: [String: Any],
                            fetchedAt: Date = Date(),
                            now: Date = Date()) -> ProviderUsage {
        let rawBuckets = (json["buckets"] as? [[String: Any]])
            ?? (json["quotas"] as? [[String: Any]])
            ?? []

        struct ParsedBucket {
            let groupID: String
            let title: String
            let isWeekly: Bool
            let window: UsageWindow
        }

        var parsed: [ParsedBucket] = []
        for bucket in rawBuckets {
            guard let remaining = flexibleDouble(bucket["remainingFraction"]) else { continue }
            let clampedRemaining = min(1.0, max(0.0, remaining))
            let usedPercent = min(100.0, max(0.0, (1.0 - clampedRemaining) * 100.0))
            let resetAt = (bucket["resetTime"] as? String).flatMap(Self.isoDate)
            let window = UsageWindow(
                percent: usedPercent,
                resetMinutes: resetAt.flatMap {
                    Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970, now: now)
                },
                resetAt: resetAt
            ).discardingIfExpired(at: now)
            guard window.percent != nil else { continue }

            let modelID = ((bucket["modelId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isWeekly = isGeminiWeeklyBucket(bucket, resetAt: resetAt, now: now)
            let (groupID, title) = geminiTierGroup(modelID: modelID)
            parsed.append(ParsedBucket(
                groupID: groupID,
                title: title,
                isWeekly: isWeekly,
                window: window
            ))
        }

        func pickWorst(_ windows: [UsageWindow]) -> UsageWindow {
            windows.max { lhs, rhs in
                let lp = lhs.percent ?? -1
                let rp = rhs.percent ?? -1
                if lp != rp { return lp < rp }
                let lr = lhs.resetAt ?? .distantFuture
                let rr = rhs.resetAt ?? .distantFuture
                return lr > rr
            } ?? UsageWindow()
        }

        let primary = pickWorst(parsed.filter { !$0.isWeekly }.map(\.window))
        let weekly = pickWorst(parsed.filter { $0.isWeekly }.map(\.window))

        // 按模型分层聚合，保留最紧张的窗口作为 scopedLimits
        var grouped: [String: (title: String, isWeekly: Bool, window: UsageWindow)] = [:]
        var order: [String] = []
        for item in parsed where !item.groupID.isEmpty {
            let key = "\(item.groupID):\(item.isWeekly ? "w" : "p")"
            if let existing = grouped[key] {
                if (item.window.percent ?? -1) > (existing.window.percent ?? -1) {
                    grouped[key] = (item.title, item.isWeekly, item.window)
                }
            } else {
                order.append(key)
                grouped[key] = (item.title, item.isWeekly, item.window)
            }
        }
        var scopedLimits: [ScopedLimit] = []
        if order.count > 1 {
            for key in order {
                guard let entry = grouped[key] else { continue }
                let suffix = entry.isWeekly ? " weekly" : ""
                scopedLimits.append(ScopedLimit(
                    id: key,
                    title: entry.title + suffix,
                    window: entry.window
                ))
            }
        }

        return ProviderUsage(
            primary: primary,
            weekly: weekly,
            scopedLimits: scopedLimits,
            fetchedAt: fetchedAt
        )
    }

    private static func isGeminiWeeklyBucket(_ bucket: [String: Any],
                                             resetAt: Date?,
                                             now: Date) -> Bool {
        if let seconds = flexibleDouble(bucket["limitWindowSeconds"])
            ?? flexibleDouble(bucket["limit_window_seconds"])
            ?? flexibleDouble(bucket["windowSeconds"]) {
            return seconds > 24 * 3600
        }
        for key in ["window", "duration", "quotaWindow", "windowType", "period"] {
            if let text = (bucket[key] as? String)?.lowercased() {
                if text.contains("week") || text.contains("7d") || text.contains("seven_day")
                    || text.contains("168h") {
                    return true
                }
                if text.contains("5h") || text.contains("5_hour") || text.contains("five_hour")
                    || text.contains("daily") || text.contains("24h") {
                    return false
                }
            }
        }
        if let resetAt {
            return resetAt.timeIntervalSince(now) > 26 * 3600
        }
        return false
    }

    private static func geminiTierGroup(modelID: String) -> (id: String, title: String) {
        let lower = modelID.lowercased()
        if lower.isEmpty { return ("", "") }
        if lower.contains("flash-lite") || lower.contains("flash_lite") {
            return ("flash-lite", "Flash Lite")
        }
        if lower.contains("flash") {
            return ("flash", "Flash")
        }
        if lower.contains("pro") {
            return ("pro", "Pro")
        }
        let cleaned = modelID.hasPrefix("gemini-") ? String(modelID.dropFirst("gemini-".count)) : modelID
        return (lower, cleaned)
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

    /// 委托刷新的成功判据。只看 Keychain：claude 刷新后写回的就是这一项，而走
    /// 完整的 token 解析链会顺带起一个登录 shell（最长 10 秒），不能放进轮询里。
    static func claudeKeychainCredentialIsValid(now: Date = Date()) -> Bool {
        guard case let .success(data) = claudeKeychainData(),
              let credential = claudeCredential(data) else { return false }
        return credential.isValid(at: now)
    }

    static func claudeKeychainData() -> Result<Data, CredentialError> {
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
        return codexCredentials(fileData: data)
    }

    /// access_token 是带 `exp` 的 JWT，实测有效期十天，由 codex CLI 自己续期。
    /// 十天没开过 codex 它就死了，而把一个已知过期的 token 发出去只会换回 401：
    /// 白费一轮请求，还把「凭据过期」说成「用量接口出错」。这里提前认出来，
    /// 面板同时回落到会话日志里的窗口。
    static func codexCredentials(fileData: Data,
                                 now: Date = Date()) -> Result<(token: String, account: String?),
                                                               CredentialError> {
        guard let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else { return .failure(.invalidCodexCredentials) }
        guard jwtIsUsable(token, at: now) else { return .failure(.expiredCodexCredentials) }
        var account = tokens["account_id"] as? String
        if account == nil, let jwt = tokens["id_token"] as? String { account = accountID(jwt: jwt) }
        return .success((token, account))
    }

    /// 没有 `exp` 的 token 视为有效——不是每个签发方都放这个字段，不能因为读不到
    /// 就丢掉唯一的凭据。留 60 秒余量，避免卡在过期边界上白发一轮。
    static func jwtIsUsable(_ jwt: String, at now: Date = Date()) -> Bool {
        guard let expiry = (jwtClaims(jwt)?["exp"] as? NSNumber)?.doubleValue else { return true }
        return expiry - now.timeIntervalSince1970 > 60
    }

    static func accountID(jwt: String) -> String? {
        guard let auth = jwtClaims(jwt)?["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }

    /// JWT 的 payload 段，base64url 解码，不验签——这里只读自己写下的声明，
    /// 验签需要公钥而我们并不用它来授权任何事。
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func isoWindow(_ value: Any?, now: Date = Date()) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["utilization"] as? NSNumber)?.doubleValue
        let resetAt = (object["resets_at"] as? String).flatMap(Self.isoDate)
        return UsageWindow(
            percent: percent,
            resetMinutes: resetAt.flatMap {
                Self.remainingMinutes(untilEpoch: $0.timeIntervalSince1970, now: now)
            },
            resetAt: resetAt
        ).discardingIfExpired(at: now)
    }

    private static func epochWindow(_ value: Any?, now: Date = Date()) -> UsageWindow {
        guard let object = value as? [String: Any] else { return UsageWindow() }
        let percent = (object["used_percent"] as? NSNumber)?.doubleValue
        // 未启用的窗口返回完整周期，reset_at 会随每次请求后移，不是真正的重置时间。
        if percent == 0,
           let duration = (object["limit_window_seconds"] as? NSNumber)?.doubleValue, duration > 0,
           let remaining = (object["reset_after_seconds"] as? NSNumber)?.doubleValue,
           remaining >= duration {
            return UsageWindow(percent: percent)
        }
        let resetAt = (object["reset_at"] as? NSNumber).map {
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
