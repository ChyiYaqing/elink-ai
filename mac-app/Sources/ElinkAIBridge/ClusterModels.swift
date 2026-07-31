import Foundation

struct ClusterSnapshotKey: Codable, Hashable {
    let originNodeID: String
    let day: String
    let provider: String
}

struct ClusterSnapshotDescriptor: Codable, Equatable {
    let key: ClusterSnapshotKey
    let revision: Int64
    let contentHash: String
}

struct ClusterUsageSnapshot: Codable, Equatable {
    let key: ClusterSnapshotKey
    let revision: Int64
    let observedAt: Date
    let models: [String: Int]
    /// 这一天的小时分布：`"0"…"23"` → 模型 → token。
    ///
    /// 可选，且 nil 与空字典意思不同：nil 是「对端没告诉我」（老版本节点、或者
    /// Linux 上的 elink-tui 还没实现），空字典才是「这天没有用量」。分不清这两者，
    /// 一台不发小时数据的节点就会在「今日」里显示成零，而不是显示成未知。
    let hours: [String: [String: Int]]?

    init(key: ClusterSnapshotKey, revision: Int64, observedAt: Date,
         models: [String: Int], hours: [String: [String: Int]]? = nil) {
        self.key = key
        self.revision = revision
        self.observedAt = observedAt
        self.models = models
        self.hours = hours
    }

    /// 内容哈希只覆盖 models：拉取与否由 revision 决定，而把小时数据算进哈希会让
    /// 新旧版本对同一份快照算出不同的值，在混版集群里永远互相不认。
    var descriptor: ClusterSnapshotDescriptor {
        ClusterSnapshotDescriptor(key: key, revision: revision, contentHash: Self.hash(models))
    }

    static func hash(_ models: [String: Int]) -> String {
        let value = models
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return ClusterCrypto.sha256(Data(value.utf8)).base64EncodedString()
    }
}

struct ClusterNodeRecord: Codable, Equatable, Identifiable {
    var id: String { nodeID }
    let nodeID: String
    var name: String
    var endpoint: String?
    var lastSeenAt: Date?
    var lastSyncAt: Date?

    func isOnline(at now: Date = Date()) -> Bool {
        lastSeenAt.map { now.timeIntervalSince($0) < 90 } ?? false
    }
}

struct ClusterLiveStatus: Codable, Equatable {
    let nodeID: String
    let nodeName: String
    let observedAt: Date
    let claude: AgentStatus
    let codex: AgentStatus
}

struct ClusterManifest: Codable {
    let protocolVersion: Int
    let clusterID: String
    let senderNodeID: String
    let senderName: String
    let liveStatuses: [ClusterLiveStatus]
    let snapshots: [ClusterSnapshotDescriptor]
}

struct ClusterPullRequest: Codable {
    let keys: [ClusterSnapshotKey]
}

struct ClusterPullResponse: Codable {
    let snapshots: [ClusterUsageSnapshot]
}

struct ClusterAnnounce: Codable {
    let descriptors: [ClusterSnapshotDescriptor]
}

struct ClusterAck: Codable {
    let ok: Bool
}

struct ClusterSecurePayload: Codable {
    let senderNodeID: String
    let sealed: String
}

struct ClusterJoinRequest: Codable {
    // 配对码不上网线：proof 是用配对码派生密钥对公钥+节点 ID 的 HMAC
    let proof: String
    let clientNodeID: String
    let clientName: String
    let clientPublicKey: String
}

struct ClusterJoinSecret: Codable {
    let clusterID: String
    let clusterSecret: String
    let timezone: String
}

struct ClusterJoinResponse: Codable {
    let serverPublicKey: String
    let sealed: String
}

struct ClusterCredentials: Codable, Equatable {
    var nodeID: String
    var nodeName: String
    var clusterID: String?
    var clusterSecret: String?
    var timezone: String?

    var isClustered: Bool { clusterID != nil && clusterSecret != nil }
}

struct DiscoveredClusterPeer: Identifiable, Equatable {
    /// 当前配对协议版本：v3 起配对码不上网线，与 v2 的 6 位明文配对码互不兼容
    static let currentPairingProtocol = 3

    var id: String { nodeID.isEmpty ? endpoint : nodeID }
    let nodeID: String
    let name: String
    let endpoint: String
    let clusterID: String?
    let pairable: Bool
    var pairingProtocol: Int = 2

    var pairingCompatible: Bool { pairingProtocol == Self.currentPairingProtocol }
}
