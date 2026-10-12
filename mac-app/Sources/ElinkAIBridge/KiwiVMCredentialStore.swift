import Foundation

enum KiwiVMCredentialError: LocalizedError, Equatable {
    case invalidVeid
    case invalidApiKey
    case tooManyServers
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidVeid:
            return tr("VM ID 必须是纯数字", "The VM ID must be digits only")
        case .invalidApiKey:
            return tr("API key 格式无效", "Invalid API key")
        case .tooManyServers:
            return tr("最多只能添加 \(KiwiVMCredentialStore.maxServers) 台服务器",
                      "At most \(KiwiVMCredentialStore.maxServers) servers can be added")
        case .storageUnavailable:
            return tr("无法写入本机数据库，凭据未保存",
                      "Could not write to the local database; the credential was not saved")
        }
    }
}

/// 一台 VPS 的接入凭据。`veid` 是 KiwiVM 里的 VM ID，也是这里的主键。
struct VpsCredential: Codable, Equatable {
    var veid: String
    /// 用户起的名字。KiwiVM 的 hostname 常年是 `xxx.localdomain`，不适合当标题。
    var label: String
    var apiKey: String
}

/// KiwiVM 凭据的落点：本机 `usage.db`，与集群密钥同处（目录 0700、库文件 0600）。
///
/// **不用 Keychain**，理由与集群凭据在 77989b1 里搬家时完全相同：这个应用是 ad-hoc
/// 签名的（`build-app.sh` 的 `codesign --sign -`），没有稳定身份，Keychain 的 ACL 绑
/// 的是二进制哈希。每次重新构建哈希都变，于是每个新版本第一次读凭据时，系统都会认为
/// 是陌生程序在窥探，向用户要一次登录密码。一个后台自己去读的凭据不该把用户拽进
/// 授权对话框——尤其是这个对话框出现时，用户正在做的事情和它毫无关系。
///
/// 代价是这份 api_key 从加密存储降级为权限保护的文件。这正是集群共享密钥已经接受的
/// 权衡，而 KiwiVM 的 api_key 权限更小：它只能读取状态，改不了任何东西。
struct KiwiVMCredentialStore {
    static let shared = KiwiVMCredentialStore()
    /// 每台每轮都是一次计量调用，给点数预算封个顶。超出时明说，不静默截断。
    static let maxServers = 4

    private let store: UsageStore

    init(store: UsageStore = .shared) {
        self.store = store
    }

    /// 记着的每一台，顺序即卡片上的顺序。
    func load() -> [VpsCredential] {
        guard let data = store.vpsCredentialsData(),
              let rows = try? JSONDecoder().decode([VpsCredential].self, from: data) else {
            return []
        }
        return Array(rows.prefix(Self.maxServers))
    }

    /// 只给 UI 用：面板永远不需要回显 api_key，取名字和 VM ID 就够了。
    func servers() -> [(veid: String, label: String)] {
        load().map { ($0.veid, $0.label) }
    }

    func save(_ credential: VpsCredential) throws {
        guard Self.normalizedVeid(credential.veid) != nil else {
            throw KiwiVMCredentialError.invalidVeid
        }
        guard Self.normalizedApiKey(credential.apiKey) != nil else {
            throw KiwiVMCredentialError.invalidApiKey
        }
        var rows = load()
        if let index = rows.firstIndex(where: { $0.veid == credential.veid }) {
            rows[index] = credential
        } else {
            guard rows.count < Self.maxServers else { throw KiwiVMCredentialError.tooManyServers }
            rows.append(credential)
        }
        try write(rows)
    }

    /// 改名不重新验证：api_key 没变，再打一次计量调用换不回任何新信息。
    /// 返回规整后的名字，调用方拿它上屏，免得卡片和存下来的不一致。
    @discardableResult
    func rename(veid: String, to label: String) throws -> String {
        let label = Self.normalizedLabel(label, veid: veid)
        var rows = load()
        guard let index = rows.firstIndex(where: { $0.veid == veid }) else { return label }
        rows[index].label = label
        try write(rows)
        return label
    }

    func remove(veid: String) throws {
        try write(load().filter { $0.veid != veid })
    }

    private func write(_ rows: [VpsCredential]) throws {
        // 一台都不剩时写空数据，由 store 把那一行删掉。
        let data = rows.isEmpty ? Data() : (try? JSONEncoder().encode(rows)) ?? Data()
        guard store.saveVPSCredentialsData(data) else {
            throw KiwiVMCredentialError.storageUnavailable
        }
    }

    // MARK: - 校验

    /// veid 会直接拼进 URL 的 query。KiwiVM 的 VM ID 就是一串十进制数字，
    /// 收紧到纯数字既能挡住注入，也能把用户粘错整行文本的情形当场说清楚。
    static func normalizedVeid(_ value: String) -> String? {
        let veid = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...12).contains(veid.count), veid.allSatisfy(\.isASCII), veid.allSatisfy(\.isNumber) else {
            return nil
        }
        return veid
    }

    static func normalizedApiKey(_ value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...512).contains(key.count),
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            return nil
        }
        return key
    }

    /// 名字只影响显示，所以不拒绝任何输入，只截断；留空则回落到 VM ID。
    static func normalizedLabel(_ value: String, veid: String) -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if label.isEmpty { return "VPS \(veid)" }
        return String(label.prefix(32))
    }
}
