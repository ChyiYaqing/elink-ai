import Foundation
import Security

enum ElinkClaudeTokenStoreError: LocalizedError, Equatable {
    case invalidToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return tr("Claude token 格式无效", "Invalid Claude token")
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            return tr("无法访问 Elink Keychain：\(detail)",
                      "Cannot access the Elink Keychain: \(detail)")
        }
    }
}

/// Elink 使用独立的 Keychain 条目保存 `claude setup-token` 生成的长期 token。
/// 不修改 Claude Code 自己的轮换凭据，避免两个进程竞争 refresh token。
struct ElinkClaudeTokenStore {
    static let shared = ElinkClaudeTokenStore()

    private let service: String
    private let account: String

    init(service: String = "ai.elink.claude-oauth-token",
         account: String = "claude-code-long-lived") {
        self.service = service
        self.account = account
    }

    func token() throws -> String? {
        guard let data = try storedData() else { return nil }
        guard let value = String(data: data, encoding: .utf8),
              let token = Self.normalizedToken(value) else {
            throw ElinkClaudeTokenStoreError.invalidToken
        }
        return token
    }

    func save(_ value: String) throws {
        guard let token = Self.normalizedToken(value),
              let data = token.data(using: .utf8) else {
            throw ElinkClaudeTokenStoreError.invalidToken
        }

        // 不能更新一个仅凭 service/account 匹配到的既有条目：恶意本地进程可
        // 预先创建同名项并保留自己的 ACL。删除后重新添加，让 Keychain 为
        // 当前应用创建新的访问控制；删除失败时绝不覆盖。
        // 旧条目即使格式已损坏也必须能被新候选值修复；回滚保存原始 Data，
        // 不能先走 token 格式解析把恢复路径堵死。
        let previousData = try storedData()
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw ElinkClaudeTokenStoreError.keychain(deleteStatus)
        }

        do {
            try add(data)
        } catch {
            // 极少数写入失败不能顺手毁掉原本可用的凭据；尽力恢复旧值后再报错。
            if let previousData {
                try? add(previousData)
            }
            throw error
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ElinkClaudeTokenStoreError.keychain(status)
        }
    }

    static func normalizedToken(_ value: String) -> String? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20,
              token.utf8.count <= 16 * 1024,
              token.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            return nil
        }
        return token
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func storedData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ElinkClaudeTokenStoreError.keychain(status) }
        guard let data = item as? Data else { throw ElinkClaudeTokenStoreError.invalidToken }
        return data
    }

    private func add(_ data: Data) throws {
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Elink AI Claude token"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ElinkClaudeTokenStoreError.keychain(status)
        }
    }
}
