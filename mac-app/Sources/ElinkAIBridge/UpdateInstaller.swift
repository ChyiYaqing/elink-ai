import AppKit
import CryptoKit
import Foundation

enum UpdateInstallError: LocalizedError, Equatable {
    case keyMissing
    case keyInvalid
    case notInstallable
    case location
    case permission
    case download(String)
    case signatureInvalid
    case packageInvalid(String)
    case unsupportedSystem(String)
    case replaceFailed
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case .keyMissing:
            return tr("此版本没有内置更新签名公钥，请手动下载安装。", "This build has no update public key; download it manually.")
        case .keyInvalid:
            return tr("内置更新签名公钥无效。", "The built-in update public key is invalid.")
        case .notInstallable:
            return tr("该版本缺少签名的更新包，请手动下载安装。", "This release has no signed update; download it manually.")
        case .location:
            return tr("Elink AI 未从“应用程序”文件夹运行，请先拖到“应用程序”再打开。",
                      "Elink AI is not running from Applications; move it there and reopen it first.")
        case .permission:
            return tr("当前用户无权替换 Elink AI 所在位置的 App。", "You are not allowed to replace the app at its current location.")
        case let .download(detail):
            return tr("下载更新失败：\(detail)", "Download failed: \(detail)")
        case .signatureInvalid:
            return tr("更新包签名校验失败，已放弃安装。", "Update signature verification failed; installation abandoned.")
        case let .packageInvalid(detail):
            return tr("更新包无效：\(detail)", "Invalid update package: \(detail)")
        case let .unsupportedSystem(minimum):
            return tr("新版本需要 macOS \(minimum) 或更高版本，已保留当前版本。",
                      "The new version requires macOS \(minimum) or later; the current version is kept.")
        case .replaceFailed:
            return tr("无法替换当前 App，原 App 保持不变。", "Cannot replace the app; the original is unchanged.")
        case .relaunchFailed:
            return tr("新版本已安装，但无法自动重启，请手动退出并重新打开 Elink AI。",
                      "The update is installed but could not relaunch; quit and reopen Elink AI manually.")
        }
    }
}

/// 自动更新：校验签名、从 DMG 取出 App、原地替换、重启。下载在 UpdateChecker 里。
enum UpdateInstaller {
    static let publicKeyInfoKey = "ElinkUpdatePublicKey"

    /// 签名在验证前不可信：Ed25519 签名的 Base64 只有 88 字节，超过上限直接拒绝，不整个读入。
    static func readSignature(_ file: URL, limit: Int = 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw UpdateInstallError.signatureInvalid }
        return data
    }

    /// Ed25519 签名，签的是 DMG 的原始字节；公钥和签名都是 Base64，公钥为 32 字节原始值。
    static func verifySignature(of file: URL, signature: Data, publicKey: String) throws {
        let keyText = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyText.isEmpty else { throw UpdateInstallError.keyMissing }
        guard let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateInstallError.keyInvalid
        }
        let signatureText = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: signatureText), raw.count == 64,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              key.isValidSignature(raw, for: data) else {
            throw UpdateInstallError.signatureInvalid
        }
    }

    /// 当前 App 不能自我替换的原因；能替换时返回 nil。
    static func locationProblem(_ bundle: URL) -> UpdateInstallError? {
        let path = bundle.resolvingSymlinksInPath().path
        guard bundle.pathExtension == "app",
              !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else {
            return .location
        }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
              manager.isWritableFile(atPath: bundle.path) else {
            return .permission
        }
        return nil
    }

    /// 与 `bundle` 同一卷上的临时目录，最后的替换因此只是两次 rename。
    static func stagingDirectory(for bundle: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: bundle, create: true)
    }

    /// 只读挂载 DMG，把其中唯一的 .app 复制到 `directory`，然后卸载。
    static func extractApp(fromDMG dmg: URL, into directory: URL) throws -> URL {
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mount.path, dmg.path],
                failure: tr("无法挂载 DMG", "cannot mount the DMG"))
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], failure: "") }

        let apps = try FileManager.default.contentsOfDirectory(atPath: mount.path).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else {
            throw UpdateInstallError.packageInvalid(tr("DMG 内容与预期不符", "unexpected DMG contents"))
        }
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let app = unpacked.appendingPathComponent(apps[0], isDirectory: true)
        try run("/usr/bin/ditto", [mount.appendingPathComponent(apps[0]).path, app.path],
                failure: tr("无法复制 App", "cannot copy the app"))
        return app
    }

    /// 新 App 必须是同一个 App（标识与可执行文件名一致）、版本号与 Release 一致，且代码签名完整。
    static func validate(_ app: URL, expectedVersion: String, bundleIdentifier: String, executable: String) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateInstallError.packageInvalid(tr("缺少有效的 App", "no valid app inside"))
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == executable else {
            throw UpdateInstallError.packageInvalid(tr("不是 Elink AI", "not Elink AI"))
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateInstallError.packageInvalid(tr("版本号与发布版本不一致", "version does not match the release"))
        }
        // 替换前确认新版能在本机运行，否则旧版会被换成打不开的 App。
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
            let required = OperatingSystemVersion(majorVersion: parts.first ?? 0,
                                                  minorVersion: parts.count > 1 ? parts[1] : 0,
                                                  patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
                throw UpdateInstallError.unsupportedSystem(minimum)
            }
        }
        // ad-hoc 签名只证明完整性；来源已由 verifySignature 证明。
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                failure: tr("代码签名不完整", "code signature is incomplete"))
    }

    /// 用 RENAME_SWAP 原子交换新旧 App：任何时刻原路径上都有一个完整版本，中途断电也不会落空。
    /// 交换后旧版落在暂存路径，随暂存目录一起删除。
    static func replace(_ bundle: URL, with staged: URL,
                        swap: (URL, URL) -> Int32 = { renamex_np($0.path, $1.path, UInt32(RENAME_SWAP)) }) throws {
        guard swap(staged, bundle) == 0 else { throw UpdateInstallError.replaceFailed }
    }

    /// 固定脚本最多等 60 秒让本进程退出，然后打开 App。pid 与路径作为参数传入，不拼进脚本。
    /// 脚本没能启动就不退出，否则没人负责重新打开 App。
    static func relaunch(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"i=0; while /bin/kill -0 "$1" 2>/dev/null && [ $i -lt 120 ]; do /bin/sleep 0.5; i=$((i+1)); done; /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$2""#,
                             "elink-relaunch", String(getpid()), bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateInstallError.relaunchFailed }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let outcome = try UpdateChecker.runCLI(URL(fileURLWithPath: tool), arguments: arguments, timeout: 120)
        guard !outcome.timedOut, outcome.status == 0 else {
            throw UpdateInstallError.packageInvalid(failure)
        }
    }
}
