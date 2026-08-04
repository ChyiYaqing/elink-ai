import AppKit
import Combine
import Foundation

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let isDraft: Bool
    let isPrerelease: Bool
    let pageURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case pageURL = "html_url"
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    var dmgURL: URL? {
        let expectedName = "elink-ai-v\(version).dmg"
        return assets.first { $0.name.caseInsensitiveCompare(expectedName) == .orderedSame }?.browserDownloadURL
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case upToDate
    case updateAvailable
    case failed(String)
}

final class UpdateChecker: ObservableObject {
    static let releasesAPI = URL(
        string: "https://api.github.com/repos/ChyiYaqing/elink-ai/releases?per_page=20"
    )!
    static let automaticCheckInterval: TimeInterval = 6 * 60 * 60

    private enum DefaultsKey {
        static let automaticallyChecks = "updates.automaticallyChecks"
        static let includesPrereleases = "updates.includesPrereleases"
        static let lastCheckedAt = "updates.lastCheckedAt"
    }

    @Published private(set) var isChecking = false
    @Published private(set) var state: UpdateCheckState = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateURL: URL?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var automaticallyChecks: Bool
    @Published private(set) var includesPrereleases: Bool

    let currentVersion: String

    private let session: URLSession
    private let defaults: UserDefaults
    private var lastAttemptAt: Date?

    init(currentVersion: String = AppInfo.version,
         session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.currentVersion = currentVersion
        self.session = session
        self.defaults = defaults
        self.automaticallyChecks = defaults.object(forKey: DefaultsKey.automaticallyChecks) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.automaticallyChecks)
        self.includesPrereleases = defaults.bool(forKey: DefaultsKey.includesPrereleases)
        self.lastCheckedAt = defaults.object(forKey: DefaultsKey.lastCheckedAt) as? Date
        self.lastAttemptAt = self.lastCheckedAt
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        Log.user("automatic update checks \(enabled ? "enabled" : "disabled")")
        automaticallyChecks = enabled
        defaults.set(enabled, forKey: DefaultsKey.automaticallyChecks)
        if enabled { checkAutomaticallyIfNeeded() }
    }

    func setIncludesPrereleases(_ enabled: Bool) {
        Log.user("prerelease updates \(enabled ? "enabled" : "disabled")")
        includesPrereleases = enabled
        defaults.set(enabled, forKey: DefaultsKey.includesPrereleases)
        check()
    }

    func checkAutomaticallyIfNeeded(now: Date = Date()) {
        guard automaticallyChecks, !isChecking else { return }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.automaticCheckInterval {
            return
        }
        check()
    }

    func check() {
        guard !isChecking else { return }
        lastAttemptAt = Date()
        isChecking = true
        state = .idle

        var request = URLRequest(url: Self.releasesAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Elink-AI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let result = Self.checkResult(
                data: data,
                response: response,
                error: error,
                currentVersion: self.currentVersion,
                includesPrereleases: self.includesPrereleases
            )
            if case .failure = result {
                self.checkWithGitHubCLI(fallback: result)
                return
            }
            DispatchQueue.main.async {
                self.finish(result)
            }
        }.resume()
    }

    func openAvailableUpdate() {
        guard let updateURL else { return }
        Log.user("open application update \(updateURL.absoluteString)")
        NSWorkspace.shared.open(updateURL)
    }

    private func finish(_ result: Result<GitHubRelease?, Error>) {
        isChecking = false
        switch result {
        case let .success(release):
            let checkedAt = Date()
            lastCheckedAt = checkedAt
            defaults.set(checkedAt, forKey: DefaultsKey.lastCheckedAt)
            if let release {
                latestVersion = release.version
                updateURL = release.dmgURL ?? release.pageURL
                state = .updateAvailable
                Log.info("update check completed: v\(release.version) available")
            } else {
                latestVersion = nil
                updateURL = nil
                state = .upToDate
                Log.info("update check completed: application is up to date")
            }
        case let .failure(error):
            state = .failed(error.localizedDescription)
            Log.warning("update check failed: \(error.localizedDescription)", category: "update")
        }
    }

    // Private repositories intentionally return 404 to anonymous API clients.
    // Fall back to the user's existing `gh auth login` session without copying
    // or persisting their GitHub token inside Elink AI.
    private func checkWithGitHubCLI(fallback: Result<GitHubRelease?, Error>) {
        guard let executable = Self.githubCLIURL() else {
            DispatchQueue.main.async {
                if case let .failure(error) = fallback,
                   case .http(404) = error as? CheckError {
                    self.finish(.failure(CheckError.privateRepositoryAuthRequired))
                } else {
                    self.finish(fallback)
                }
            }
            return
        }

        let arguments = [
            "api",
            "repos/ChyiYaqing/elink-ai/releases?per_page=20",
            "--jq",
            "[.[] | {tag_name,draft,prerelease,html_url,assets:[.assets[] | {name,browser_download_url}]}]",
        ]

        do {
            let outcome = try Self.runCLI(executable, arguments: arguments, timeout: Self.cliTimeout)
            if !outcome.timedOut, outcome.status == 0 {
                let result = Self.releaseResult(
                    data: outcome.stdout,
                    currentVersion: currentVersion,
                    includesPrereleases: includesPrereleases
                )
                DispatchQueue.main.async { self.finish(result) }
            } else {
                let detail = outcome.timedOut
                    ? tr("命令超时", "command timed out")
                    : String(data: outcome.stderr, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.finish(.failure(CheckError.githubCLI(detail)))
                }
            }
        } catch {
            DispatchQueue.main.async {
                if case let .failure(originalError) = fallback {
                    self.finish(.failure(originalError))
                } else {
                    self.finish(.failure(CheckError.network(error.localizedDescription)))
                }
            }
        }
    }

    struct CLIOutcome {
        let stdout: Data
        let stderr: Data
        let status: Int32
        let timedOut: Bool
    }

    static let cliTimeout: TimeInterval = 30

    /// 超时收割队列：只发信号，永不阻塞，因此一条串行队列足够。
    private static let cliReaper = DispatchQueue(label: "ai.elink.update-cli-reaper")

    /// 两个管道都必须在等待退出之前排空。gh 写满 stdout 或 stderr 的内核缓冲区
    /// （约 64KB）就会阻塞在 write() 上，而调用方在 `waitUntilExit()` 等它退出 ——
    /// 双方互等，永久死锁，且没有任何超时。这条路径尤其致命：仓库是私有的，
    /// 匿名 API 必然 404，所以每次检查都会走到 gh 回退；一旦卡住，`isChecking`
    /// 再也回不到 false，更新检查在整个进程生命周期内彻底失效。
    ///
    /// 只排空一个管道不够 —— 另一个写满照样卡住 gh，所以 stderr 交给一条后台
    /// 线程，stdout 留在当前线程读，两者并发。超时由只发 SIGKILL 的 timer source
    /// 兜底：SIGKILL 不可被忽略或阻塞，子进程必死、两个管道必然 EOF，两处读取
    /// 因此必然返回，那条后台线程也一定会被释放。
    nonisolated static func runCLI(_ executable: URL, arguments: [String],
                                   timeout: TimeInterval) throws -> CLIOutcome {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // pid 被收割后可能立即复用，届时 SIGKILL 会打到无关进程上。
        let pid = process.processIdentifier
        let lock = NSLock()
        var reaped = false
        let killer = DispatchSource.makeTimerSource(queue: cliReaper)
        killer.schedule(deadline: .now() + timeout)
        killer.setEventHandler { lock.holding { if !reaped { kill(pid, SIGKILL) } } }
        killer.resume()

        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        lock.holding { reaped = true }
        killer.cancel()

        return CLIOutcome(stdout: outputData, stderr: errorData,
                          status: process.terminationStatus,
                          timedOut: process.terminationReason != .exit)
    }

    private enum CheckError: LocalizedError {
        case network(String)
        case invalidResponse
        case http(Int)
        case invalidData
        case privateRepositoryAuthRequired
        case githubCLI(String?)

        var errorDescription: String? {
            switch self {
            case let .network(message): return message
            case .invalidResponse: return tr("GitHub 返回了无效响应", "GitHub returned an invalid response")
            case let .http(status): return tr("GitHub 请求失败（HTTP \(status)）", "GitHub request failed (HTTP \(status))")
            case .invalidData: return tr("无法解析 GitHub Release 信息", "Cannot parse GitHub release info")
            case .privateRepositoryAuthRequired:
                return tr("私有仓库需要先安装 GitHub CLI 并执行 gh auth login",
                          "Private repository requires GitHub CLI installed and gh auth login")
            case let .githubCLI(detail):
                if let detail, !detail.isEmpty { return tr("GitHub CLI：\(detail)", "GitHub CLI: \(detail)") }
                return tr("GitHub CLI 认证失败", "GitHub CLI authentication failed")
            }
        }
    }

    nonisolated static func githubCLIURL() -> URL? {
        var candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/gh" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func checkResult(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        currentVersion: String,
        includesPrereleases: Bool
    ) -> Result<GitHubRelease?, Error> {
        if let error { return .failure(CheckError.network(error.localizedDescription)) }
        guard let response = response as? HTTPURLResponse else {
            return .failure(CheckError.invalidResponse)
        }
        guard response.statusCode == 200 else {
            return .failure(CheckError.http(response.statusCode))
        }
        return releaseResult(
            data: data,
            currentVersion: currentVersion,
            includesPrereleases: includesPrereleases
        )
    }

    nonisolated static func releaseResult(
        data: Data?,
        currentVersion: String,
        includesPrereleases: Bool
    ) -> Result<GitHubRelease?, Error> {
        guard let data,
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return .failure(CheckError.invalidData)
        }
        let release = newestRelease(in: releases, includesPrereleases: includesPrereleases)
        guard let release, isVersion(release.version, newerThan: currentVersion) else {
            return .success(nil)
        }
        return .success(release)
    }

    nonisolated static func newestRelease(
        in releases: [GitHubRelease],
        includesPrereleases: Bool
    ) -> GitHubRelease? {
        releases
            .filter { !$0.isDraft && (includesPrereleases || !$0.isPrerelease) }
            .max { lhs, rhs in isVersion(rhs.version, newerThan: lhs.version) }
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        compareVersions(candidate, current) == .orderedDescending
    }

    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = ParsedVersion(lhs)
        let right = ParsedVersion(rhs)

        for index in 0..<max(left.core.count, right.core.count) {
            let a = index < left.core.count ? left.core[index] : 0
            let b = index < right.core.count ? right.core[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (leftParts?, rightParts?):
            for index in 0..<max(leftParts.count, rightParts.count) {
                guard index < leftParts.count else { return .orderedAscending }
                guard index < rightParts.count else { return .orderedDescending }
                let a = leftParts[index]
                let b = rightParts[index]
                if a == b { continue }
                if let aNumber = Int(a), let bNumber = Int(b) {
                    return aNumber < bNumber ? .orderedAscending : .orderedDescending
                }
                if Int(a) != nil { return .orderedAscending }
                if Int(b) != nil { return .orderedDescending }
                return a.localizedStandardCompare(b)
            }
            return .orderedSame
        }
    }

    private struct ParsedVersion {
        let core: [Int]
        let prerelease: [String]?

        init(_ raw: String) {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix("v")
                .split(separator: "+", maxSplits: 1)
                .first
                .map(String.init) ?? raw
            let pieces = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            core = pieces[0].split(separator: ".").map { Int($0) ?? 0 }
            prerelease = pieces.count > 1
                ? pieces[1].split(separator: ".").map(String.init)
                : nil
        }
    }
}
