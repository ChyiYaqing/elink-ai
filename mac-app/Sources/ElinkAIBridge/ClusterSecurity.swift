import CryptoKit
import Foundation
import Security

enum ClusterCryptoError: LocalizedError {
    case invalidCredentials
    case invalidPayload
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "集群凭据无效"
        case .invalidPayload: return "同步数据格式无效"
        case .authenticationFailed: return "同步请求认证失败"
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

    private static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
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

        let name = Host.current().localizedName ?? "Mac"
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
            throw BridgeError.message("无法将集群凭据写入 usage.db")
        }
        try? FileManager.default.removeItem(at: legacyFallbackURL)
    }
}
