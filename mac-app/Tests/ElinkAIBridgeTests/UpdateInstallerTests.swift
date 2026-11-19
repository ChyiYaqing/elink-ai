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
        let file = directory.appendingPathComponent("update.dmg")
        try data.write(to: file)
        return (file, Data(try key.signature(for: data).base64EncodedString().utf8))
    }

    // MARK: - 签名

    func testValidSignatureIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (file, signature) = try signed(Data("dmg".utf8), with: key)
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(
            of: file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testTamperedFileIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (file, signature) = try signed(Data("dmg".utf8), with: key)
        try Data("evil".utf8).write(to: file)
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(
            of: file, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString())) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
    }

    func testSignatureFromAnotherKeyIsRejected() throws {
        let (file, signature) = try signed(Data("dmg".utf8), with: Curve25519.Signing.PrivateKey())
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: file, signature: signature, publicKey: other)) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
    }

    func testMissingPublicKeyIsReported() throws {
        let (file, signature) = try signed(Data("dmg".utf8), with: Curve25519.Signing.PrivateKey())
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

    func testInstallAssetsRequireDMGAndSignature() throws {
        let base = "https://github.com/ChyiYaqing/elink-ai/releases/download/v0.2.0/"
        let complete = try release([("elink-ai-v0.2.0.dmg", base + "elink-ai-v0.2.0.dmg"),
                                    ("elink-ai-v0.2.0.dmg.sig", base + "elink-ai-v0.2.0.dmg.sig")])
        XCTAssertEqual(complete.installAssets?.dmgName, "elink-ai-v0.2.0.dmg")
        XCTAssertNil(try release([("elink-ai-v0.2.0.dmg", base + "elink-ai-v0.2.0.dmg")]).installAssets)
    }

    func testInstallAssetsMustComeFromGitHub() throws {
        let release = try release([("elink-ai-v0.2.0.dmg", "https://example.com/elink-ai-v0.2.0.dmg"),
                                   ("elink-ai-v0.2.0.dmg.sig", "https://github.com/x/elink-ai-v0.2.0.dmg.sig")])
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
        let file = directory.appendingPathComponent("update.dmg.sig")
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

    // MARK: - DMG 端到端：验签 → 挂载取出 → 校验

    private func makeDMG(version: String) throws -> URL {
        let root = directory.appendingPathComponent("dmg-root", isDirectory: true)
        let app = root.appendingPathComponent("Elink AI.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("ElinkAIBridge").path)
        let info: [String: Any] = ["CFBundleIdentifier": "local.elink-ai.bridge", "CFBundleExecutable": "ElinkAIBridge",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        try shell("/usr/bin/codesign", "--force", "--deep", "--sign", "-", app.path)
        let dmg = directory.appendingPathComponent("elink-ai-v\(version).dmg")
        try shell("/usr/bin/hdiutil", "create", "-quiet", "-volname", "Elink AI", "-srcfolder", root.path,
                  "-format", "UDZO", dmg.path)
        return dmg
    }

    private func shell(_ tool: String, _ arguments: String...) throws {
        let outcome = try UpdateChecker.runCLI(URL(fileURLWithPath: tool), arguments: arguments, timeout: 120)
        XCTAssertEqual(outcome.status, 0, String(decoding: outcome.stderr, as: UTF8.self))
    }

    func testSignedDMGYieldsAValidatedApp() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dmg = try makeDMG(version: "0.2.0")
        let signature = Data(try key.signature(for: Data(contentsOf: dmg)).base64EncodedString().utf8)
        try UpdateInstaller.verifySignature(of: dmg, signature: signature,
                                            publicKey: key.publicKey.rawRepresentation.base64EncodedString())

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        let app = try UpdateInstaller.extractApp(fromDMG: dmg, into: staging)
        XCTAssertEqual(app.lastPathComponent, "Elink AI.app")
        XCTAssertNoThrow(try UpdateInstaller.validate(app, expectedVersion: "0.2.0",
                                                      bundleIdentifier: "local.elink-ai.bridge", executable: "ElinkAIBridge"))
        XCTAssertThrowsError(try UpdateInstaller.validate(app, expectedVersion: "0.3.0",
                                                          bundleIdentifier: "local.elink-ai.bridge", executable: "ElinkAIBridge"))
        XCTAssertThrowsError(try UpdateInstaller.validate(app, expectedVersion: "0.2.0",
                                                          bundleIdentifier: "com.example.other", executable: "ElinkAIBridge"))
        // 取出后 DMG 已卸载。
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("mount").path), [])
    }
}
