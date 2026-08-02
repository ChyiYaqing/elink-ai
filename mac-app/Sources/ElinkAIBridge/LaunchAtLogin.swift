import Foundation

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.1.20-rc3"
    static let repoURL = URL(string: "https://github.com/ChyiYaqing/elink-ai")!
    static let logDirectoryURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Elink AI", isDirectory: true)
    static let logURL = logDirectoryURL.appendingPathComponent("elink-ai.log")
    static let archivedLogURL = logDirectoryURL.appendingPathComponent("elink-ai.1.log")
    static let consoleLogURL = logDirectoryURL.appendingPathComponent("elink-ai-console.log")
    static let logPath = logURL.path
    static let legacyLogPath = "/tmp/elink-ai-bridge.log"
}

// 通过 ~/Library/LaunchAgents 的 launchd plist 实现开机自启动
// （SPM 裸可执行文件无法使用 SMAppService，需要 .app 包）
enum LaunchAtLogin {
    static let defaultPlistPath =
        ("~/Library/LaunchAgents/local.elink-ai-bridge.plist" as NSString).expandingTildeInPath

    static func isEnabled(at path: String = defaultPlistPath) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func refreshIfEnabled(at path: String = defaultPlistPath) throws {
        guard isEnabled(at: path) else { return }
        try setEnabled(true, at: path)
    }

    static func setEnabled(_ enabled: Bool, at path: String = defaultPlistPath) throws {
        guard enabled else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try FileManager.default.createDirectory(
            at: AppInfo.logDirectoryURL,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": "local.elink-ai-bridge",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "StandardOutPath": AppInfo.consoleLogURL.path,
            "StandardErrorPath": AppInfo.consoleLogURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
