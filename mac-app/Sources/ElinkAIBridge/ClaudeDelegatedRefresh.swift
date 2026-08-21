import Foundation

/// Claude Code 是惰性续期：只有它自己要发请求、发现手里的 access token 快过期
/// 时才刷新并写回 Keychain。开着但空闲的会话不发请求，也就不刷新，Keychain 里
/// 的条目会一路烂到过期——面板于是在「token 过期」到「用户下次真的用一下
/// Claude Code」之间一直读到过期凭据（实测一次空窗 32 分钟）。
///
/// 这里不拿 refreshToken 自己去换新的：refresh token 是轮换的，抢它等于和
/// Claude Code 争同一条链，一次失败就能把用户的登录状态弄坏。改成启动一次
/// claude，让它按自己的流程刷新，然后观察凭据有没有真的变得可用。
///
/// 实测（claude 2.1.232）：刷新发生在启动后约 2.1 秒，没有 TTY 时进程约 2.5 秒
/// 自行退出，不需要 PTY、不需要输入任何斜杠命令、不消耗 token。
enum ClaudeDelegatedRefresh {
    /// 观察到凭据续上后的冷却。新 access token 有 8 小时寿命，五分钟内不可能
    /// 需要第二次。
    static let successCooldown: TimeInterval = 300
    /// 没能续上时的冷却。这种情况多半是 refresh token 也废了、只能重新登录，
    /// 按 120 秒的用量刷新节奏反复起进程毫无意义。用户手动刷新绕过冷却，所以
    /// 拉长它不会让人干等。
    static let failureCooldown: TimeInterval = 600

    private static let pollInterval: TimeInterval = 0.5
    private static let observationWindow: TimeInterval = 10

    private static let lock = NSLock()
    private static var nextAllowed = Date.distantPast

    /// - Parameters:
    ///   - userInitiated: 用户主动刷新时绕过冷却。
    ///   - credentialIsUsable: 每轮重新判定一次凭据现在是否可用。判据必须是
    ///     「现在能用了」而不是「claude 跑完了」：refresh token 同样失效时进程
    ///     也干净退出，把那当成功只会顶着冷却继续显示过期。
    /// - Returns: 是否观察到凭据续上——只有 true 才值得重新读一次 token。
    static func attempt(userInitiated: Bool,
                        now: Date = Date(),
                        credentialIsUsable: () -> Bool) -> Bool {
        guard reserve(userInitiated: userInitiated, now: now) else { return false }

        guard let binary = claudeBinary() else {
            record(cooldown: failureCooldown)
            Log.warning("claude delegated refresh skipped: claude not found", category: "usage")
            return false
        }

        let process = launch(binary: binary)
        let renewed = waitForRenewal(process: process, credentialIsUsable: credentialIsUsable)
        if let process, process.isRunning { process.terminate() }

        record(cooldown: renewed ? successCooldown : failureCooldown)
        if renewed {
            Log.info("claude delegated refresh renewed the credential", category: "usage")
        } else {
            Log.warning("claude delegated refresh did not renew the credential", category: "usage")
        }
        return renewed
    }

    static func shouldAttempt(now: Date, nextAllowed: Date, userInitiated: Bool) -> Bool {
        userInitiated || now >= nextAllowed
    }

    static func claudeBinary(
        candidates: [String] = UsageFetcher.claudeBinaryCandidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .first(where: isExecutable)
    }

    static func touchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        // 带着 API key 或长期 token 启动的 claude 走的是另一条鉴权路径，根本不会
        // 去碰 OAuth 凭据，这一趟就白跑了。
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        // 一个被动探针不该顺手把用户的 claude 升级掉。
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    private static func reserve(userInitiated: Bool, now: Date) -> Bool {
        lock.holding {
            guard shouldAttempt(now: now, nextAllowed: nextAllowed,
                               userInitiated: userInitiated) else { return false }
            // 先按失败冷却占位，避免两路刷新同时起 claude；结束时再按结果覆盖。
            nextAllowed = now.addingTimeInterval(failureCooldown)
            return true
        }
    }

    private static func record(cooldown: TimeInterval) {
        lock.holding { nextAllowed = Date().addingTimeInterval(cooldown) }
    }

    private static func launch(binary: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // --strict-mcp-config 不去初始化用户配置的 MCP server：那会拖慢启动，还会
        // 顺手拉起一串与刷新无关的进程。这一趟也不需要任何工具。
        process.arguments = ["--allowed-tools", "", "--strict-mcp-config"]
        process.currentDirectoryURL = probeDirectory()
        process.environment = touchEnvironment()
        // 没有 TTY 时 claude 会在刷新之后自行退出，所以不用喂输入，也不用怕它
        // 停在交互提示上等人。
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            Log.warning("claude delegated refresh could not start claude", category: "usage")
            return nil
        }
        return process
    }

    /// 不在用户的工程目录里起 claude：那会把探针会话写进用户的项目记录，还会撞上
    /// 目录信任提示。
    private static func probeDirectory() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElinkAI/claude-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        return directory
    }

    private static func waitForRenewal(process: Process?,
                                       credentialIsUsable: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(observationWindow)
        while Date() < deadline {
            if credentialIsUsable() { return true }
            // 写回发生在退出之前，但两者只隔几百毫秒；进程没了就再看一轮收尾。
            if let process, !process.isRunning {
                Thread.sleep(forTimeInterval: pollInterval)
                return credentialIsUsable()
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return credentialIsUsable()
    }
}
