import CryptoKit
import Foundation
import Security

enum ClusterCryptoError: LocalizedError {
    case invalidCredentials
    case invalidPayload
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return tr("集群凭据无效", "Invalid cluster credentials")
        case .invalidPayload: return tr("同步数据格式无效", "Invalid sync data format")
        case .authenticationFailed: return tr("同步请求认证失败", "Sync request authentication failed")
        }
    }
}

enum ClusterCrypto {
    static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .secondsSince1970
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .secondsSince1970
        return value
    }()

    static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data(UUID().uuidString.utf8).prefix(count)
        }
        return Data(bytes)
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func clusterKey(_ credentials: ClusterCredentials) throws -> SymmetricKey {
        guard let encoded = credentials.clusterSecret,
              let data = Data(base64Encoded: encoded), data.count >= 32 else {
            throw ClusterCryptoError.invalidCredentials
        }
        return SymmetricKey(data: data)
    }

    static func derivedKey(_ key: SymmetricKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data("elink-ai-cluster-v2".utf8),
            info: Data(purpose.utf8),
            outputByteCount: 32
        )
    }

    // 配对码 16 字符（~78 bit 熵），只在两台主机的屏幕间带外传递、绝不上网线：
    // 它同时充当 ECDH 密钥的盐和入群证明的 HMAC 密钥，主动中间人替换公钥后
    // 也无法在可行时间内离线暴破出会话密钥
    static let pairingCodeLength = 16
    private static let pairingCodeAlphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    static func generatePairingCode() -> String {
        var result = ""
        while result.count < pairingCodeLength {
            for byte in [UInt8](randomData(count: 32)) {
                guard result.count < pairingCodeLength else { break }
                // 拒绝采样消除模偏差：256 - 256 % 30 = 240
                if byte < 240 {
                    result.append(pairingCodeAlphabet[Int(byte) % pairingCodeAlphabet.count])
                }
            }
        }
        return result
    }

    static func normalizedPairingCode(_ value: String) -> String? {
        let stripped = value.uppercased().filter { $0 != "-" && $0 != " " }
        guard stripped.count == pairingCodeLength,
              stripped.allSatisfy({ pairingCodeAlphabet.contains($0) }) else { return nil }
        return stripped
    }

    static func formattedPairingCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: min(4, code.count - offset))
            return String(code[start..<end])
        }.joined(separator: "-")
    }

    /// 客户端证明自己知道配对码；把公钥和节点 ID 绑进 HMAC，防止中间人换公钥后重放证明
    static func pairingProof(code: String, clientPublicKey: Data, clientNodeID: String) -> String {
        let key = SymmetricKey(data: sha256(Data(code.utf8)))
        let payload = clientPublicKey + Data(clientNodeID.utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
            .base64EncodedString()
    }

    static func pairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey,
                           peerPublicKey: Data, code: String) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sha256(Data(code.utf8)),
            sharedInfo: Data("elink-ai-pair-v2".utf8),
            outputByteCount: 32
        )
    }

    static func seal<T: Encodable>(_ value: T, key: SymmetricKey,
                                   senderNodeID: String) throws -> Data {
        let plaintext = try encoder.encode(value)
        let encryptionKey = derivedKey(key, purpose: "encryption")
        let sealed = try AES.GCM.seal(
            plaintext,
            using: encryptionKey,
            authenticating: Data(senderNodeID.utf8)
        )
        guard let combined = sealed.combined else { throw ClusterCryptoError.invalidPayload }
        return try encoder.encode(ClusterSecurePayload(
            senderNodeID: senderNodeID,
            sealed: combined.base64EncodedString()
        ))
    }

    static func open<T: Decodable>(_ type: T.Type, data: Data,
                                   key: SymmetricKey) throws -> (String, T) {
        let envelope = try decoder.decode(ClusterSecurePayload.self, from: data)
        guard let combined = Data(base64Encoded: envelope.sealed) else {
            throw ClusterCryptoError.invalidPayload
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(
            box,
            using: derivedKey(key, purpose: "encryption"),
            authenticating: Data(envelope.senderNodeID.utf8)
        )
        return (envelope.senderNodeID, try decoder.decode(type, from: plaintext))
    }

    static func signedHeaders(method: String, path: String, body: Data,
                              nodeID: String, key: SymmetricKey,
                              now: Date = Date(), nonce: String = UUID().uuidString) -> [String: String] {
        let timestamp = String(Int(now.timeIntervalSince1970))
        let signature = requestSignature(
            method: method, path: path, timestamp: timestamp, nonce: nonce,
            body: body, key: key
        )
        return [
            "X-Elink-Node": nodeID,
            "X-Elink-Timestamp": timestamp,
            "X-Elink-Nonce": nonce,
            "X-Elink-Signature": signature,
        ]
    }

    static func verify(method: String, path: String, body: Data,
                       headers: [String: String], key: SymmetricKey,
                       now: Date = Date()) -> (nodeID: String, nonce: String)? {
        guard let nodeID = headers["x-elink-node"],
              let timestamp = headers["x-elink-timestamp"],
              let seconds = TimeInterval(timestamp),
              abs(now.timeIntervalSince1970 - seconds) <= 60,
              let nonce = headers["x-elink-nonce"],
              let supplied = headers["x-elink-signature"] else { return nil }
        let expected = requestSignature(
            method: method, path: path, timestamp: timestamp, nonce: nonce,
            body: body, key: key
        )
        return constantTimeEqual(supplied, expected) ? (nodeID, nonce) : nil
    }

    private static func requestSignature(method: String, path: String, timestamp: String,
                                         nonce: String, body: Data, key: SymmetricKey) -> String {
        let canonical = [
            method.uppercased(), path, timestamp, nonce,
            sha256(body).base64EncodedString(),
        ].joined(separator: "\n")
        let authKey = derivedKey(key, purpose: "authentication")
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8), using: authKey
        )).base64EncodedString()
    }

    static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let lhs = Array(first.utf8)
        let rhs = Array(second.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

final class ClusterCredentialStore {
    private let store: UsageStore
    private let legacyFallbackURL: URL

    static var defaultLegacyFallbackURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElinkAI", isDirectory: true)
            .appendingPathComponent("cluster-credentials-v2.json")
    }

    init(store: UsageStore,
         legacyFallbackURL: URL = ClusterCredentialStore.defaultLegacyFallbackURL) {
        self.store = store
        self.legacyFallbackURL = legacyFallbackURL
    }

    func loadOrCreate() -> ClusterCredentials {
        if let data = store.clusterCredentialsData(),
           let value = try? ClusterCrypto.decoder.decode(ClusterCredentials.self, from: data) {
            return value
        }

        // Migrate only the file fallback used by pre-SQLite builds. Deliberately
        // never query the old Keychain item, because even reading it can display
        // an authorization prompt for ad-hoc signed builds.
        if let data = try? Data(contentsOf: legacyFallbackURL),
           let value = try? ClusterCrypto.decoder.decode(ClusterCredentials.self, from: data) {
            if store.saveClusterCredentialsData(data) {
                try? FileManager.default.removeItem(at: legacyFallbackURL)
                Log.info("migrated cluster credentials into usage.db", category: "cluster")
            }
            return value
        }

        let name = Host.current().localizedName ?? "Host"
        let value = ClusterCredentials(
            nodeID: UUID().uuidString.lowercased(),
            nodeName: name,
            clusterID: nil,
            clusterSecret: nil,
            timezone: nil
        )
        do { try save(value) }
        catch { Log.warning("cluster credentials could not be persisted: \(error.localizedDescription)", category: "cluster") }
        return value
    }

    func save(_ value: ClusterCredentials) throws {
        let data = try ClusterCrypto.encoder.encode(value)
        guard store.saveClusterCredentialsData(data) else {
            throw BridgeError.message(tr("无法将集群凭据写入 usage.db", "Cannot write cluster credentials to usage.db"))
        }
        try? FileManager.default.removeItem(at: legacyFallbackURL)
    }

    /// 切换集群时用：换凭据和清旧集群数据在同一个 SQLite 事务里完成
    func save(_ value: ClusterCredentials, resettingRemoteDataExcept localNodeID: String) throws {
        let data = try ClusterCrypto.encoder.encode(value)
        guard store.saveClusterCredentialsData(
            data, resettingRemoteDataExceptNodeID: localNodeID
        ) else {
            throw BridgeError.message(tr("无法将集群凭据写入 usage.db", "Cannot write cluster credentials to usage.db"))
        }
        try? FileManager.default.removeItem(at: legacyFallbackURL)
    }
}
