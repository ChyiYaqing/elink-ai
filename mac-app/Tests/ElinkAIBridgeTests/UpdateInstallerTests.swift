import CryptoKit
import XCTest
@testable import ElinkAIBridge

final class UpdateInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func signed(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> (URL, Data) {
        let file = directory.appendingPathComponent("update.zip")
        try data.write(to: file)
        return (file, Data(try key.signature(for: data).base64EncodedString().utf8))
    }

    // MARK: - 签名

    func testValidSignatureIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (file, signature) = try signed(Data("archive".utf8), with: key)
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(
            of: file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testTamperedFileIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (file, signature) = try signed(Data("archive".utf8), with: key)
        try Data("evil".utf8).write(to: file)
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(
            of: file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString())) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
    }

    func testSignatureFromAnotherKeyIsRejected() throws {
        let (file, signature) = try signed(Data("archive".utf8), with: Curve25519.Signing.PrivateKey())
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: file, signature: signature, publicKey: other)) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
    }

    func testMissingPublicKeyIsReported() throws {
        let (file, signature) = try signed(Data("archive".utf8), with: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: file, signature: signature, publicKey: " ")) {
            XCTAssertEqual($0 as? UpdateInstallError, .keyMissing)
        }
    }

    func testEmbeddedAndSigningPublicKeysAreValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Info.plist")) as? [String: Any])
        let embedded = try XCTUnwrap(info[UpdateInstaller.publicKeyInfoKey] as? String)
        let signing = try String(contentsOf: root.appendingPathComponent("update-signing-public-key"), encoding: .utf8)
        for key in [embedded, signing.trimmingCharacters(in: .whitespacesAndNewlines)] {
            XCTAssertNotNil(Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
        }
    }

    // MARK: - Release 资源

    private func release(_ assets: [(String, String)]) throws -> GitHubRelease {
        let json: [String: Any] = [
            "tag_name": "v0.2.0", "draft": false, "prerelease": false,
            "html_url": "https://github.com/ChyiYaqing/elink-ai/releases/tag/v0.2.0",
            "assets": assets.map { ["name": $0.0, "browser_download_url": $0.1] },
        ]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testInstallAssetsRequireArchiveAndSignature() throws {
        let base = "https://github.com/ChyiYaqing/elink-ai/releases/download/v0.2.0/"
        let complete = try release([("elink-ai-v0.2.0.dmg", base + "elink-ai-v0.2.0.dmg"),
                                    ("elink-ai-v0.2.0.zip", base + "elink-ai-v0.2.0.zip"),
                                    ("elink-ai-v0.2.0.zip.sig", base + "elink-ai-v0.2.0.zip.sig")])
        XCTAssertEqual(complete.installAssets?.archiveName, "elink-ai-v0.2.0.zip")
        // 只有 DMG 和 DMG 签名（v0.1.21-rc16）不能自动安装：App 无权读取挂载的 DMG。
        XCTAssertNil(try release([("elink-ai-v0.2.0.dmg", base + "elink-ai-v0.2.0.dmg"),
                                  ("elink-ai-v0.2.0.dmg.sig", base + "elink-ai-v0.2.0.dmg.sig")]).installAssets)
        XCTAssertNil(try release([("elink-ai-v0.2.0.zip", base + "elink-ai-v0.2.0.zip")]).installAssets)
    }

    func testInstallAssetsMustComeFromGitHub() throws {
        let release = try release([("elink-ai-v0.2.0.zip", "https://example.com/elink-ai-v0.2.0.zip"),
                                   ("elink-ai-v0.2.0.zip.sig", "https://github.com/x/elink-ai-v0.2.0.zip.sig")])
        XCTAssertNil(release.installAssets)
    }

    // MARK: - 位置与替换

    func testAppsOutsideAWritableFolderCannotReplaceThemselves() {
        XCTAssertEqual(UpdateInstaller.locationProblem(URL(fileURLWithPath: "/Volumes/Elink AI/Elink AI.app")), .location)
        XCTAssertEqual(UpdateInstaller.locationProblem(directory.appendingPathComponent("debug")), .location)
    }

    func testReplaceSwapsTheBundleAtomically() throws {
        let bundle = directory.appendingPathComponent("Elink AI.app")
        let staged = directory.appendingPathComponent("staged.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: bundle.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        XCTAssertNil(UpdateInstaller.locationProblem(bundle))

        try UpdateInstaller.replace(bundle, with: staged)

        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("marker")), Data("new".utf8))
        // 旧版换到暂存路径，随暂存目录一起清理。
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("marker")), Data("old".utf8))
    }

    func testFailedSwapLeavesTheOriginal() throws {
        let bundle = directory.appendingPathComponent("Elink AI.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstaller.replace(bundle, with: directory.appendingPathComponent("missing.app"))) {
            XCTAssertEqual($0 as? UpdateInstallError, .replaceFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testOversizedSignatureIsRejectedWithoutReadingIt() throws {
        let file = directory.appendingPathComponent("update.zip.sig")
        try Data(count: 10 * 1024 * 1024).write(to: file)
        XCTAssertThrowsError(try UpdateInstaller.readSignature(file)) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
    }

    func testAppRequiringNewerMacOSIsRejected() throws {
        let app = directory.appendingPathComponent("Elink AI.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.elink-ai.bridge", "CFBundleExecutable": "ElinkAIBridge",
                                   "CFBundleShortVersionString": "0.2.0", "LSMinimumSystemVersion": "99.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try UpdateInstaller.validate(app, expectedVersion: "0.2.0",
                                                          bundleIdentifier: "local.elink-ai.bridge", executable: "ElinkAIBridge")) {
            XCTAssertEqual($0 as? UpdateInstallError, .unsupportedSystem("99.0"))
        }
    }

    // MARK: - 端到端：与 build-dmg.sh 相同的方式打包 → 验签 → 解压 → 校验

    private func makeApp(version: String, in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Elink AI.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("ElinkAIBridge").path)
        let info: [String: Any] = ["CFBundleIdentifier": "local.elink-ai.bridge", "CFBundleExecutable": "ElinkAIBridge",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path)
        return app
    }

    private func shell(_ tool: String, _ arguments: String...) throws {
        let outcome = try UpdateChecker.runCLI(URL(fileURLWithPath: tool), arguments: arguments, timeout: 120)
        XCTAssertEqual(outcome.status, 0, String(decoding: outcome.stderr, as: UTF8.self))
    }

    func testSignedArchiveYieldsAValidatedApp() throws {
        let app = try makeApp(version: "0.2.0", in: directory.appendingPathComponent("build", isDirectory: true))
        let archive = directory.appendingPathComponent("elink-ai-v0.2.0.zip")
        try shell("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path)
        let key = Curve25519.Signing.PrivateKey()
        let signature = Data(try key.signature(for: Data(contentsOf: archive)).base64EncodedString().utf8)
        try UpdateInstaller.verifySignature(of: archive, signature: signature,
                                            publicKey: key.publicKey.rawRepresentation.base64EncodedString())

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        let extracted = try UpdateInstaller.extractApp(fromArchive: archive, into: staging)
        XCTAssertEqual(extracted.lastPathComponent, "Elink AI.app")
        XCTAssertNoThrow(try UpdateInstaller.validate(extracted, expectedVersion: "0.2.0",
                                                      bundleIdentifier: "local.elink-ai.bridge", executable: "ElinkAIBridge"))
        XCTAssertThrowsError(try UpdateInstaller.validate(extracted, expectedVersion: "0.3.0",
                                                          bundleIdentifier: "local.elink-ai.bridge", executable: "ElinkAIBridge"))
        XCTAssertThrowsError(try UpdateInstaller.validate(extracted, expectedVersion: "0.2.0",
                                                          bundleIdentifier: "com.example.other", executable: "ElinkAIBridge"))
    }

    func testArchiveWithExtraEntriesIsRejected() throws {
        let root = directory.appendingPathComponent("build", isDirectory: true)
        _ = try makeApp(version: "0.2.0", in: root)
        try Data("x".utf8).write(to: root.appendingPathComponent("extra.txt"))
        let archive = directory.appendingPathComponent("extra.zip")
        try shell("/usr/bin/ditto", "-c", "-k", root.path, archive.path)
        XCTAssertThrowsError(try UpdateInstaller.extractApp(fromArchive: archive,
                                                            into: directory.appendingPathComponent("staging"))) {
            guard case .packageInvalid = $0 as? UpdateInstallError else { return XCTFail("\($0)") }
        }
    }
}
