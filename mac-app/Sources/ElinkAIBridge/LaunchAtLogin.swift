import Foundation

enum AppInfo {
    static let version = "0.1.1"
    static let repoURL = URL(string: "https://github.com/ChyiYaqing/elink-ai")!
    static let logPath = "/tmp/elink-ai-bridge.log"
}

// 通过 ~/Library/LaunchAgents 的 launchd plist 实现开机自启动
// （SPM 裸可执行文件无法使用 SMAppService，需要 .app 包）
enum LaunchAtLogin {
    static let defaultPlistPath =
        ("~/Library/LaunchAgents/local.elink-ai-bridge.plist" as NSString).expandingTildeInPath

    static func isEnabled(at path: String = defaultPlistPath) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func setEnabled(_ enabled: Bool, at path: String = defaultPlistPath) throws {
        guard enabled else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": "local.elink-ai-bridge",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "StandardOutPath": AppInfo.logPath,
            "StandardErrorPath": AppInfo.logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
