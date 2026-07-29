import CryptoKit
import Foundation

final class ClusterManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var clusterID: String?
    @Published private(set) var nodes: [ClusterNodeRecord] = []
    @Published private(set) var discoveredPeers: [DiscoveredClusterPeer] = []
    @Published private(set) var pairingCode: String?
    @Published private(set) var lastError: String?
    @Published private(set) var syncing = false

    var localStatusProvider: (() -> BridgeSnapshot)?
    /// 聚合时区实际变化（入群/退群）后触发；宿主据此调度用量维护任务，
    /// 迁移起点由持久化的“已应用分桶时区”决定，与凭据的瞬时旧值无关
    var onAggregationTimeZoneChange: (() -> Void)?

    private struct PairingState {
        let code: String
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let expiresAt: Date
        var attempts: Int
    }

    private let store: UsageStore
    private let credentialStore: ClusterCredentialStore
    private let discovery = ClusterDiscovery()
    private let lock = NSLock()
    private var credentials: ClusterCredentials
    // @Published 属性只能在主线程读写；后台线程使用这份锁保护的镜像
    private var knownPeers: [DiscoveredClusterPeer] = []
    private var liveStatuses: [String: ClusterLiveStatus] = [:]
    private var replayNonces: [String: Date] = [:]
    // 每次保存凭据（建群/入群/退群）时 +1；在途同步回包若代数不符则丢弃，
    // 避免旧集群的响应写进新集群的数据库
    private var credentialsGeneration = 0
    private var pairing: PairingState?
    private var syncTimer: Timer?
    private var pairingTimer: Timer?
    private var announceWork: DispatchWorkItem?
    private var port: UInt16 = 8765
    private let session: URLSession
    private let manualPeersKey = "elink_cluster_manual_peers_v2"

    init(store: UsageStore, credentials: ClusterCredentials? = nil,
         credentialStore: ClusterCredentialStore? = nil,
         session: URLSession? = nil) {
        self.store = store
        let resolvedCredentialStore = credentialStore ?? ClusterCredentialStore(store: store)
        self.credentialStore = resolvedCredentialStore
        self.credentials = credentials ?? resolvedCredentialStore.loadOrCreate()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
        enabled = self.credentials.isClustered
        clusterID = self.credentials.clusterID
        StatusService.setAggregationTimeZone(self.credentials.timezone)
        store.configureClusterStorage(
            nodeID: self.credentials.nodeID,
            nodeName: self.credentials.nodeName,
            aggregationEnabled: self.credentials.isClustered
        )
        store.onClusterUsageChange = { [weak self] descriptors in
            self?.scheduleAnnounce(descriptors)
        }
        discovery.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.lock.holding { self.knownPeers = peers }
            self.discoveredPeers = peers
            if self.enabled { self.syncAll() }
        }
        refreshPublishedState()
    }

    deinit {
        syncTimer?.invalidate()
        pairingTimer?.invalidate()
        discovery.stop()
    }

    var nodeID: String { lock.holding { credentials.nodeID } }
    var nodeName: String { lock.holding { credentials.nodeName } }
    /// 本机节点记录不保存 endpoint，节点详情用局域网地址加同步端口展示
    var localEndpoint: String? {
        DeviceClient.localIPv4().map { endpoint(host: $0, port: Int(port)) }
    }
    private var isClusteredNow: Bool { lock.holding { credentials.isClustered } }
    private var currentClusterID: String? { lock.holding { credentials.clusterID } }

    func start(port: UInt16) {
        self.port = port
        let value = lock.holding { credentials }
        discovery.start(
            nodeID: value.nodeID,
            nodeName: value.nodeName,
            clusterID: value.clusterID,
            pairable: false,
            port: port
        )
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.syncAll()
        }
        if enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.syncAll() }
        }
    }

    func routes() -> [HTTPRouteKey: HTTPServer.Route] {
        [
            // v2 配对（6 位明文配对码）已废弃；返回明确错误而不是解码失败的笼统 400
            HTTPRouteKey("POST", "/v2/cluster/pair/join"): { _ in
                .error("pairing protocol upgraded; update both apps", status: 426)
            },
            HTTPRouteKey("POST", "/v3/cluster/pair/join"): { [weak self] in
                self?.handleJoin($0) ?? .error("cluster unavailable", status: 503)
            },
            HTTPRouteKey("GET", "/v2/cluster/manifest"): { [weak self] in
                self?.handleManifest($0) ?? .error("cluster unavailable", status: 503)
            },
            HTTPRouteKey("POST", "/v2/cluster/pull"): { [weak self] in
                self?.handlePull($0) ?? .error("cluster unavailable", status: 503)
            },
            HTTPRouteKey("POST", "/v2/cluster/announce"): { [weak self] in
                self?.handleAnnounce($0) ?? .error("cluster unavailable", status: 503)
            },
        ]
    }

    @discardableResult
    func createCluster() -> Bool {
        var value = lock.holding { credentials }
        value.clusterID = UUID().uuidString.lowercased()
        value.clusterSecret = ClusterCrypto.randomData(count: 32).base64EncodedString()
        value.timezone = TimeZone.current.identifier
        // 凭据保存与旧数据清理是一个事务；失败时一切保持原样
        guard saveCredentials(value, resetRemoteData: true) else { return false }
        UserDefaults.standard.removeObject(forKey: manualPeersKey)
        Log.user("created usage sync cluster")
        return true
    }

    func leaveCluster() {
        var value = lock.holding { credentials }
        value.clusterID = nil
        value.clusterSecret = nil
        value.timezone = nil
        guard saveCredentials(value, resetRemoteData: true) else { return }
        UserDefaults.standard.removeObject(forKey: manualPeersKey)
        stopPairing()
        Log.user("left usage sync cluster")
    }

    @discardableResult
    func startPairing() -> String? {
        guard enabled else {
            lastError = tr("请先创建同步集群", "Create a sync cluster first")
            return nil
        }
        let code = ClusterCrypto.generatePairingCode()
        lock.holding {
            pairing = PairingState(
                code: code,
                privateKey: Curve25519.KeyAgreement.PrivateKey(),
                expiresAt: Date().addingTimeInterval(120),
                attempts: 0
            )
        }
        pairingCode = ClusterCrypto.formattedPairingCode(code)
        discovery.update(nodeName: nodeName, clusterID: clusterID, pairable: true)
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.stopPairing()
        }
        return code
    }

    func stopPairing() {
        lock.holding { pairing = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pairingCode = nil
            self.discovery.update(nodeName: self.nodeName, clusterID: self.clusterID, pairable: false)
        }
    }

    func joinCluster(endpoint: String, code: String, completion: @escaping (Error?) -> Void) {
        guard let base = normalizedEndpoint(endpoint),
              let pairingCode = ClusterCrypto.normalizedPairingCode(code) else {
            completion(BridgeError.message(tr("请输入有效的节点地址和 16 位配对码",
                                               "Enter a valid node address and 16-character pairing code")))
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let (value, generation) = lock.holding { (credentials, credentialsGeneration) }
        let clientPublicKey = privateKey.publicKey.rawRepresentation
        let payload = ClusterJoinRequest(
            proof: ClusterCrypto.pairingProof(
                code: pairingCode,
                clientPublicKey: clientPublicKey,
                clientNodeID: value.nodeID
            ),
            clientNodeID: value.nodeID,
            clientName: value.nodeName,
            clientPublicKey: clientPublicKey.base64EncodedString()
        )
        guard let body = try? ClusterCrypto.encoder.encode(payload),
              let url = URL(string: base + "/v3/cluster/pair/join") else {
            completion(ClusterCryptoError.invalidPayload)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { return DispatchQueue.main.async { completion(error) } }
            // 426 是对方明确宣告的协议升级；404 则可能是旧版本、也可能地址根本
            // 不是 Elink AI 桥接端口（任何 HTTP 服务都会 404），提示不能只说版本
            if let http = response as? HTTPURLResponse, http.statusCode == 426 {
                return DispatchQueue.main.async {
                    completion(BridgeError.message(tr("对方 Elink AI 版本不兼容，请把两台主机都升级到最新版",
                                                      "The other Elink AI version is incompatible. Upgrade both hosts to the latest version.")))
                }
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return DispatchQueue.main.async {
                    completion(BridgeError.message(tr(
                        "对方没有配对接口：请确认地址是另一台主机的 Elink AI（端口 8765），或将其升级到最新版",
                        "Cannot find the pairing endpoint: make sure the address points to another host's Elink AI (port 8765), or upgrade it to the latest version."
                    )))
                }
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let joined = try? ClusterCrypto.decoder.decode(ClusterJoinResponse.self, from: data),
                  let serverPublic = Data(base64Encoded: joined.serverPublicKey),
                  let sealedData = Data(base64Encoded: joined.sealed) else {
                return DispatchQueue.main.async {
                    completion(BridgeError.message(tr("配对失败，请确认配对码尚未过期",
                                                      "Pairing failed. Make sure the pairing code has not expired.")))
                }
            }
            do {
                let key = try ClusterCrypto.pairingKey(
                    privateKey: privateKey, peerPublicKey: serverPublic, code: pairingCode
                )
                let (_, secret) = try ClusterCrypto.open(
                    ClusterJoinSecret.self, data: sealedData, key: key
                )
                var updated = value
                updated.clusterID = secret.clusterID
                updated.clusterSecret = secret.clusterSecret
                updated.timezone = secret.timezone
                DispatchQueue.main.async {
                    // 请求发出后若用户已建群、入群或退群，旧响应不能覆盖新凭据
                    guard self.lock.holding({ self.credentialsGeneration }) == generation else {
                        completion(BridgeError.message(tr("配对已取消：集群配置已变化",
                                                          "Pairing canceled: cluster configuration changed")))
                        return
                    }
                    // 换凭据 + 清旧数据是一个事务；失败时旧集群状态原样保留
                    guard self.saveCredentials(updated, resetRemoteData: true) else {
                        completion(BridgeError.message(tr("集群凭据保存失败，请重试",
                                                          "Failed to save cluster credentials. Please retry.")))
                        return
                    }
                    UserDefaults.standard.set([base], forKey: self.manualPeersKey)
                    self.stopPairing()
                    self.syncPeer(base)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }.resume()
    }

    func addManualEndpoint(_ endpoint: String) {
        guard let value = normalizedEndpoint(endpoint) else { return }
        var peers = UserDefaults.standard.stringArray(forKey: manualPeersKey) ?? []
        if !peers.contains(value) { peers.append(value) }
        UserDefaults.standard.set(peers, forKey: manualPeersKey)
    }

    func syncAll(completion: ((Error?) -> Void)? = nil) {
        guard enabled else {
            completion?(BridgeError.message(tr("请先创建或加入同步集群", "Create or join a sync cluster first")))
            return
        }
        let endpoints = knownEndpoints()
        guard !endpoints.isEmpty else {
            refreshPublishedState()
            completion?(BridgeError.message(tr("尚无已配对节点，请先在另一台主机使用配对码加入",
                                               "No paired nodes yet. On another host, join using the pairing code first.")))
            return
        }
        syncing = true
        let group = DispatchGroup()
        let resultLock = NSLock()
        var firstError: Error?
        for endpoint in endpoints {
            group.enter()
            syncPeer(endpoint) { error in
                if let error {
                    resultLock.holding {
                        if firstError == nil { firstError = error }
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let error = resultLock.holding { firstError }
            self?.syncing = false
            self?.refreshPublishedState()
            if let error { self?.setError(error.localizedDescription) }
            else { self?.lastError = nil }
            completion?(error)
        }
    }

    func aggregate(local: BridgeSnapshot, now: Date = Date()) -> BridgeSnapshot {
        guard isClusteredNow else { return local }
        store.upsertClusterNode(ClusterNodeRecord(
            nodeID: nodeID,
            name: nodeName,
            endpoint: nil,
            lastSeenAt: now,
            lastSyncAt: nil
        ))
        var result = local
        let today = StatusService.dayKey(now)
        let rows = store.clusterUsage(provider: "claude", since: today)
            + store.clusterUsage(provider: "codex", since: today)
        let live = lock.holding { Array(liveStatuses.values) }
            + [ClusterLiveStatus(
                nodeID: nodeID,
                nodeName: nodeName,
                observedAt: now,
                claude: local.claude,
                codex: local.codex
            )]
        result.claude = aggregateProvider(
            "claude", rows: rows, statuses: live.map { ($0.observedAt, $0.claude) }, now: now
        )
        result.codex = aggregateProvider(
            "codex", rows: rows, statuses: live.map { ($0.observedAt, $0.codex) }, now: now
        )
        result.usageFetchedAt = StatusService.latestUsageFetchedAt(
            claude: result.claude.usageFetchedAt,
            codex: result.codex.usageFetchedAt
        )
        let records = store.clusterNodes()
        let online = records.filter { $0.isOnline(at: now) }.count
        result.cluster = ClusterSummary(
            enabled: true,
            nodeCount: max(1, records.count),
            onlineCount: max(1, online),
            lastSyncedAt: records.compactMap(\.lastSyncAt).max()
        )
        return result
    }

    private func aggregateProvider(_ provider: String, rows: [DailyModelUsage],
                                   statuses: [(Date, AgentStatus)], now: Date) -> AgentStatus {
        var models: [String: Int] = [:]
        for row in rows where row.provider == provider { models[row.model, default: 0] += row.tokens }
        let sortedModels = models.map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
        let online = statuses.filter { now.timeIntervalSince($0.0) < 90 }
        let preferred = Self.preferredUsageStatus(statuses, now: now)
        var value = preferred ?? AgentStatus()
        value.tokensToday = sortedModels.reduce(0) { $0 + $1.tokens }
        value.modelUsageToday = sortedModels
        if online.contains(where: { $0.1.state == "working" }) { value.state = "working" }
        else if !online.isEmpty { value.state = "idle" }
        else { value.state = "offline" }
        value.needsInput = online.contains { $0.1.needsInput }
        value.primary = value.primary.discardingIfExpired(at: now)
        value.weekly = value.weekly.discardingIfExpired(at: now)
        return value
    }

    static func preferredUsageStatus(_ statuses: [(Date, AgentStatus)], now: Date,
                                     errorFreeTolerance: TimeInterval = 10 * 60) -> AgentStatus? {
        let normalized = statuses.map { candidate -> (Date, AgentStatus) in
            var value = candidate.1
            value.primary = value.primary.discardingIfExpired(at: now)
            value.weekly = value.weekly.discardingIfExpired(at: now)
            return (candidate.0, value)
        }
        let withUsage = normalized.filter {
            $0.1.primary.percent != nil || $0.1.weekly.percent != nil
        }
        let candidates = withUsage.isEmpty ? normalized : withUsage
        guard let newest = candidates.map({ $0.1.usageFetchedAt ?? $0.0 }).max() else {
            return nil
        }
        let recent = candidates.filter {
            newest.timeIntervalSince($0.1.usageFetchedAt ?? $0.0) <= errorFreeTolerance
        }
        let errorFree = recent.filter { $0.1.error == nil }
        let preferred = errorFree.isEmpty ? recent : errorFree
        return preferred.max {
            ($0.1.usageFetchedAt ?? $0.0) < ($1.1.usageFetchedAt ?? $1.0)
        }?.1
    }

    // MARK: - Server routes

    private func handleJoin(_ request: HTTPRequest) -> HTTPResponse {
        guard let join = try? ClusterCrypto.decoder.decode(ClusterJoinRequest.self, from: request.body),
              let clientPublic = Data(base64Encoded: join.clientPublicKey) else {
            return .error("invalid pairing request", status: 400)
        }
        let state: PairingState? = lock.holding {
            guard var current = pairing,
                  current.expiresAt > Date(), current.attempts < 5 else {
                pairing = nil
                return nil
            }
            current.attempts += 1
            pairing = current
            let expected = ClusterCrypto.pairingProof(
                code: current.code,
                clientPublicKey: clientPublic,
                clientNodeID: join.clientNodeID
            )
            return ClusterCrypto.constantTimeEqual(expected, join.proof) ? current : nil
        }
        guard let state else { return .error("pairing code rejected", status: 403) }
        let value = lock.holding { credentials }
        guard let clusterID = value.clusterID,
              let clusterSecret = value.clusterSecret,
              let timezone = value.timezone else {
            return .error("cluster unavailable", status: 409)
        }
        do {
            let key = try ClusterCrypto.pairingKey(
                privateKey: state.privateKey, peerPublicKey: clientPublic, code: state.code
            )
            let secret = ClusterJoinSecret(
                clusterID: clusterID, clusterSecret: clusterSecret, timezone: timezone
            )
            let sealed = try ClusterCrypto.seal(secret, key: key, senderNodeID: value.nodeID)
            store.upsertClusterNode(ClusterNodeRecord(
                nodeID: join.clientNodeID,
                name: join.clientName,
                endpoint: endpoint(host: request.peer, port: Int(port)),
                lastSeenAt: Date(),
                lastSyncAt: nil
            ))
            DispatchQueue.main.async { [weak self] in self?.refreshPublishedState() }
            stopPairing()
            return .json(ClusterJoinResponse(
                serverPublicKey: state.privateKey.publicKey.rawRepresentation.base64EncodedString(),
                sealed: sealed.base64EncodedString()
            ))
        } catch {
            return .error("pairing failed", status: 400)
        }
    }

    private func handleManifest(_ request: HTTPRequest) -> HTTPResponse {
        guard let auth = authorize(request) else { return .error("unauthorized", status: 401) }
        let local = localStatusProvider?() ?? BridgeSnapshot()
        let localLive = ClusterLiveStatus(
            nodeID: nodeID, nodeName: nodeName, observedAt: Date(),
            claude: local.claude, codex: local.codex
        )
        var knownLive = lock.holding { liveStatuses }
        knownLive[nodeID] = localLive
        let manifest = ClusterManifest(
            protocolVersion: 2,
            clusterID: currentClusterID ?? "",
            senderNodeID: nodeID,
            senderName: nodeName,
            liveStatuses: knownLive.values.filter {
                Date().timeIntervalSince($0.observedAt) < 7 * 24 * 60 * 60
            }.sorted { $0.nodeID < $1.nodeID },
            snapshots: store.clusterManifest()
        )
        return secureResponse(manifest, key: auth.key)
    }

    private func handlePull(_ request: HTTPRequest) -> HTTPResponse {
        guard let auth = authorize(request),
              let (sender, pull) = try? ClusterCrypto.open(
                ClusterPullRequest.self, data: request.body, key: auth.key
              ), sender == auth.nodeID else { return .error("unauthorized", status: 401) }
        let snapshots = store.clusterSnapshots(keys: Array(pull.keys.prefix(200)))
        return secureResponse(ClusterPullResponse(snapshots: snapshots), key: auth.key)
    }

    private func handleAnnounce(_ request: HTTPRequest) -> HTTPResponse {
        guard let auth = authorize(request),
              let (sender, _) = try? ClusterCrypto.open(
                ClusterAnnounce.self, data: request.body, key: auth.key
              ), sender == auth.nodeID else { return .error("unauthorized", status: 401) }
        let peerEndpoint = endpoint(host: request.peer, port: Int(port))
        DispatchQueue.main.async { [weak self] in self?.syncPeer(peerEndpoint) }
        return secureResponse(ClusterAck(ok: true), key: auth.key)
    }

    private func authorize(_ request: HTTPRequest) -> (nodeID: String, key: SymmetricKey)? {
        guard let key = try? ClusterCrypto.clusterKey(lock.holding({ credentials })),
              let verified = ClusterCrypto.verify(
                method: request.method, path: request.path, body: request.body,
                headers: request.headers, key: key
              ) else { return nil }
        let accepted = lock.holding { () -> Bool in
            let cutoff = Date().addingTimeInterval(-300)
            replayNonces = replayNonces.filter { $0.value > cutoff }
            guard replayNonces[verified.nonce] == nil else { return false }
            replayNonces[verified.nonce] = Date()
            return true
        }
        return accepted ? (verified.nodeID, key) : nil
    }

    private func secureResponse<T: Encodable>(_ value: T, key: SymmetricKey) -> HTTPResponse {
        do { return .json(try ClusterCrypto.seal(value, key: key, senderNodeID: nodeID)) }
        catch { return .error("encryption failed", status: 500) }
    }

    // MARK: - Client synchronization

    private func syncPeer(_ endpoint: String, completion: ((Error?) -> Void)? = nil) {
        let (key, generation) = lock.holding {
            ((try? ClusterCrypto.clusterKey(credentials)), credentialsGeneration)
        }
        // epoch 在 store 队列内与 reset 全序校验，写入前的最后防线
        let epoch = store.clusterDataEpoch()
        guard isClusteredNow, let key,
              let url = URL(string: endpoint + "/v2/cluster/manifest") else {
            completion?(BridgeError.message(tr("同步配置无效", "Invalid sync configuration"))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ClusterCrypto.signedHeaders(
            method: "GET", path: "/v2/cluster/manifest", body: Data(),
            nodeID: nodeID, key: key
        ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { completion?(BridgeError.message(tr("同步服务已停止", "Sync service stopped"))); return }
            if let error { completion?(error); return }
            guard let http = response as? HTTPURLResponse else {
                completion?(BridgeError.message(tr("节点 \(endpoint) 没有返回有效响应",
                                                   "Node \(endpoint) returned no valid response")))
                return
            }
            guard http.statusCode == 200 else {
                let message = http.statusCode == 401
                    ? tr("节点 \(endpoint) 尚未加入当前同步集群，请先使用配对码加入",
                         "Node \(endpoint) has not joined the current sync cluster. Join with a pairing code first.")
                    : tr("节点 \(endpoint) 返回 HTTP \(http.statusCode)",
                         "Node \(endpoint) returned HTTP \(http.statusCode)")
                completion?(BridgeError.message(message))
                return
            }
            guard let data,
                  let (_, manifest) = try? ClusterCrypto.open(
                    ClusterManifest.self, data: data, key: key
                  ), manifest.protocolVersion == 2,
                  manifest.clusterID == self.currentClusterID else {
                completion?(BridgeError.message(tr("节点 \(endpoint) 不属于当前同步集群",
                                                   "Node \(endpoint) does not belong to the current sync cluster")))
                return
            }
            guard manifest.senderNodeID != self.nodeID else {
                completion?(BridgeError.message(tr("节点地址 \(endpoint) 指向本机",
                                                   "Node address \(endpoint) points to this machine")))
                return
            }
            // 响应回来时若已切换集群（凭据代数变化），丢弃整包，避免旧集群数据落库
            guard self.lock.holding({ self.credentialsGeneration }) == generation else {
                completion?(BridgeError.message(tr("同步已取消：集群配置已变化",
                                                   "Sync canceled: cluster configuration changed")))
                return
            }
            let now = Date()
            self.lock.holding {
                // 代数复核与写入同锁：切换集群后旧响应不能污染内存状态
                guard self.credentialsGeneration == generation else { return }
                for live in manifest.liveStatuses {
                    if self.liveStatuses[live.nodeID].map({ $0.observedAt >= live.observedAt }) == true {
                        continue
                    }
                    self.liveStatuses[live.nodeID] = live
                }
            }
            // lastSyncAt 在所有 pull 成功后才写入，失败的同步不能显示为“已同步”
            self.store.upsertRemoteClusterNode(ClusterNodeRecord(
                nodeID: manifest.senderNodeID,
                name: manifest.senderName,
                endpoint: endpoint,
                lastSeenAt: now,
                lastSyncAt: nil
            ), ifEpoch: epoch)
            for live in manifest.liveStatuses where live.nodeID != manifest.senderNodeID {
                self.store.upsertRemoteClusterNode(ClusterNodeRecord(
                    nodeID: live.nodeID,
                    name: live.nodeName,
                    endpoint: nil,
                    lastSeenAt: live.observedAt,
                    lastSyncAt: nil
                ), ifEpoch: epoch)
            }
            let local = Dictionary(uniqueKeysWithValues: self.store.clusterManifest().map { ($0.key, $0) })
            let missing = manifest.snapshots.filter {
                guard let current = local[$0.key] else { return true }
                return $0.revision > current.revision
            }.map(\.key)
            let finish: (Error?) -> Void = { error in
                var finalError = error
                if finalError == nil,
                   self.lock.holding({ self.credentialsGeneration }) != generation {
                    finalError = BridgeError.message(tr("同步已取消：集群配置已变化",
                                                        "Sync canceled: cluster configuration changed"))
                }
                if finalError == nil {
                    let accepted = self.store.upsertRemoteClusterNode(ClusterNodeRecord(
                        nodeID: manifest.senderNodeID,
                        name: manifest.senderName,
                        endpoint: endpoint,
                        lastSeenAt: now,
                        lastSyncAt: Date()
                    ), ifEpoch: epoch)
                    if !accepted {
                        finalError = BridgeError.message(tr(
                            "同步状态未写入：集群配置已变化或本地存储失败",
                            "Sync status not written: cluster configuration changed or local storage failed"
                        ))
                    }
                }
                DispatchQueue.main.async { self.refreshPublishedState() }
                completion?(finalError)
            }
            if missing.isEmpty {
                finish(nil)
                return
            }
            let pulls = DispatchGroup()
            let pullLock = NSLock()
            var firstPullError: Error?
            for start in stride(from: 0, to: missing.count, by: 200) {
                let end = min(start + 200, missing.count)
                pulls.enter()
                self.pull(Array(missing[start..<end]), from: endpoint, key: key,
                          generation: generation, epoch: epoch) { error in
                    if let error {
                        pullLock.holding {
                            if firstPullError == nil { firstPullError = error }
                        }
                    }
                    pulls.leave()
                }
            }
            pulls.notify(queue: .main) { finish(pullLock.holding { firstPullError }) }
        }.resume()
    }

    private func pull(_ keys: [ClusterSnapshotKey], from endpoint: String, key: SymmetricKey,
                      generation: Int, epoch: Int, completion: ((Error?) -> Void)? = nil) {
        do {
            let body = try ClusterCrypto.seal(
                ClusterPullRequest(keys: keys), key: key, senderNodeID: nodeID
            )
            guard let url = URL(string: endpoint + "/v2/cluster/pull") else {
                completion?(BridgeError.message(tr("节点地址无效", "Invalid node address")))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ClusterCrypto.signedHeaders(
                method: "POST", path: "/v2/cluster/pull", body: body,
                nodeID: nodeID, key: key
            ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else {
                    completion?(BridgeError.message(tr("同步服务已停止", "Sync service stopped")))
                    return
                }
                if let error { completion?(error); return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    completion?(BridgeError.message(tr("节点 \(endpoint) 拉取失败 HTTP \(status)",
                                                       "Node \(endpoint) pull failed HTTP \(status)")))
                    return
                }
                guard let data,
                      let (_, pulled) = try? ClusterCrypto.open(
                        ClusterPullResponse.self, data: data, key: key
                      ) else {
                    completion?(BridgeError.message(tr("节点 \(endpoint) 拉取响应无法解密",
                                                       "Node \(endpoint) pull response cannot be decrypted")))
                    return
                }
                // ifEpoch 在 store 队列内校验，与 reset 原子互斥；nil 表示整包被拒绝
                guard self.store.mergeClusterSnapshots(pulled.snapshots, ifEpoch: epoch) != nil else {
                    completion?(BridgeError.message(tr("同步数据未写入：集群配置已变化或本地存储失败",
                                                       "Sync data not written: cluster configuration changed or local storage failed")))
                    return
                }
                DispatchQueue.main.async { self.refreshPublishedState() }
                completion?(nil)
            }.resume()
        } catch {
            setError(error.localizedDescription)
            completion?(error)
        }
    }

    private func scheduleAnnounce(_ descriptors: [ClusterSnapshotDescriptor]) {
        guard isClusteredNow, !descriptors.isEmpty else { return }
        announceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announce(descriptors) }
        announceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func announce(_ descriptors: [ClusterSnapshotDescriptor]) {
        guard let key = try? ClusterCrypto.clusterKey(lock.holding({ credentials })) else { return }
        for endpoint in knownEndpoints() {
            do {
                let body = try ClusterCrypto.seal(
                    ClusterAnnounce(descriptors: descriptors), key: key, senderNodeID: nodeID
                )
                guard let url = URL(string: endpoint + "/v2/cluster/announce") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ClusterCrypto.signedHeaders(
                    method: "POST", path: "/v2/cluster/announce", body: body,
                    nodeID: nodeID, key: key
                ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                session.dataTask(with: request).resume()
            } catch { setError(error.localizedDescription) }
        }
    }

    private func knownEndpoints() -> [String] {
        let (currentCluster, currentNode, peers) = lock.holding {
            (credentials.clusterID, credentials.nodeID, knownPeers)
        }
        let discovered = peers.filter {
            $0.clusterID == currentCluster && $0.nodeID != currentNode
        }.map(\.endpoint)
        let manual = UserDefaults.standard.stringArray(forKey: manualPeersKey) ?? []
        let stored = store.clusterNodes().compactMap(\.endpoint)
        return Array(Set(discovered + manual + stored)).sorted()
    }

    private func normalizedEndpoint(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.hasPrefix("http://") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host else { return nil }
        return endpoint(host: host, port: url.port ?? Int(port))
    }

    private func endpoint(host: String, port: Int) -> String {
        let formatted = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "http://\(formatted):\(port)"
    }

    @discardableResult
    private func saveCredentials(_ value: ClusterCredentials, resetRemoteData: Bool = false) -> Bool {
        let previousTimeZone = Self.resolvedTimeZone(lock.holding { credentials.timezone })
        do {
            if resetRemoteData {
                // 换凭据 + 清旧集群数据是一个事务：中途退出不会出现“新密钥配旧数据”
                try credentialStore.save(value, resettingRemoteDataExcept: value.nodeID)
            } else {
                try credentialStore.save(value)
            }
            lock.holding {
                credentials = value
                credentialsGeneration += 1
                if resetRemoteData {
                    // 内存中的旧集群状态同样不能带进新集群
                    liveStatuses.removeAll()
                    replayNonces.removeAll()
                }
            }
            enabled = value.isClustered
            clusterID = value.clusterID
            store.setClusterAggregationEnabled(value.isClustered)
            StatusService.setAggregationTimeZone(value.timezone)
            discovery.update(
                nodeName: value.nodeName,
                clusterID: value.clusterID,
                pairable: pairingCode != nil
            )
            lastError = nil
            refreshPublishedState()
            if Self.resolvedTimeZone(value.timezone) != previousTimeZone {
                onAggregationTimeZoneChange?()
            }
            return true
        } catch {
            setError(error.localizedDescription)
            return false
        }
    }

    private static func resolvedTimeZone(_ identifier: String?) -> String {
        (identifier.flatMap(TimeZone.init(identifier:)) ?? .current).identifier
    }

    private func refreshPublishedState() {
        let records = store.clusterNodes()
        if Thread.isMainThread { nodes = records }
        else { DispatchQueue.main.async { [weak self] in self?.nodes = records } }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
            Log.warning(message, category: "cluster")
        }
    }
}
