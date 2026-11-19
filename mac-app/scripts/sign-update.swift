// 给 Release DMG 生成软件更新签名（Ed25519，签的是 DMG 的原始字节）。
//
// 用法：ELINK_UPDATE_SIGNING_KEY=<私钥> swift scripts/sign-update.swift <DMG> <内置公钥>
//
// 私钥是 Base64 编码的 32 字节原始私钥，只经环境变量传入，不出现在命令行里。
// 签名前确认它与 App 内置公钥（Info.plist 的 ElinkUpdatePublicKey）配对，
// 签完用公钥回验一次，最后把签名的 Base64 文本写到 stdout。
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: sign-update.swift <dmg> <public-key>") }

let keyText = (ProcessInfo.processInfo.environment["ELINK_UPDATE_SIGNING_KEY"] ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !keyText.isEmpty else { fail("ELINK_UPDATE_SIGNING_KEY is not configured") }
guard let keyData = Data(base64Encoded: keyText),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    fail("ELINK_UPDATE_SIGNING_KEY is not a Base64 raw Ed25519 private key")
}
guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[2] else {
    fail("Signing key does not match the public key embedded in the app")
}

guard let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe) else {
    fail("Cannot read \(arguments[1])")
}
guard let signature = try? key.signature(for: archive),
      key.publicKey.isValidSignature(signature, for: archive) else {
    fail("Signature verification failed")
}
print(signature.base64EncodedString())
