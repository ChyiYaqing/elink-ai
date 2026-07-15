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
    private var liveStatuses: [String: ClusterLiveStatus] = [:]
    private var replayNonces: [String: Date] = [:]
    private var pairing: PairingState?
    private var syncTimer: Timer?
    private var pairingTimer: Timer?
    private var announceWork: DispatchWorkItem?
    private var port: UInt16 = 8765
    private let session: URLSession
    private let manualPeersKey = "elink_cluster_manual_peers_v2"

    init(store: UsageStore, credentials: ClusterCredentials? = nil,
         credentialStore: ClusterCredentialStore = ClusterCredentialStore()) {
        self.store = store
        self.credentialStore = credentialStore
        self.credentials = credentials ?? credentialStore.loadOrCreate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
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
            HTTPRouteKey("POST", "/v2/cluster/pair/join"): { [weak self] in
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

    func createCluster() {
        var value = lock.holding { credentials }
        store.resetRemoteClusterData(localNodeID: value.nodeID)
        UserDefaults.standard.removeObject(forKey: manualPeersKey)
        value.clusterID = UUID().uuidString.lowercased()
        value.clusterSecret = ClusterCrypto.randomData(count: 32).base64EncodedString()
        value.timezone = TimeZone.current.identifier
        saveCredentials(value)
        Log.user("created usage sync cluster")
    }

    func leaveCluster() {
        var value = lock.holding { credentials }
        store.resetRemoteClusterData(localNodeID: value.nodeID)
        UserDefaults.standard.removeObject(forKey: manualPeersKey)
        value.clusterID = nil
        value.clusterSecret = nil
        value.timezone = nil
        saveCredentials(value)
        lock.holding { liveStatuses.removeAll() }
        stopPairing()
        Log.user("left usage sync cluster")
    }

    @discardableResult
    func startPairing() -> String? {
        guard enabled else {
            lastError = "请先创建同步集群"
            return nil
        }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        lock.holding {
            pairing = PairingState(
                code: code,
                privateKey: Curve25519.KeyAgreement.PrivateKey(),
                expiresAt: Date().addingTimeInterval(120),
                attempts: 0
            )
        }
        pairingCode = code
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
        let pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = normalizedEndpoint(endpoint), pairingCode.count == 6,
              pairingCode.allSatisfy(\.isNumber) else {
            completion(BridgeError.message("请输入有效的节点地址和 6 位配对码"))
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let value = lock.holding { credentials }
        let payload = ClusterJoinRequest(
            code: pairingCode,
            clientNodeID: value.nodeID,
            clientName: value.nodeName,
            clientPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        guard let body = try? ClusterCrypto.encoder.encode(payload),
              let url = URL(string: base + "/v2/cluster/pair/join") else {
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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let joined = try? ClusterCrypto.decoder.decode(ClusterJoinResponse.self, from: data),
                  let serverPublic = Data(base64Encoded: joined.serverPublicKey),
                  let sealedData = Data(base64Encoded: joined.sealed) else {
                return DispatchQueue.main.async {
                    completion(BridgeError.message("配对失败，请确认配对码尚未过期"))
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
                self.store.resetRemoteClusterData(localNodeID: updated.nodeID)
                UserDefaults.standard.set([base], forKey: self.manualPeersKey)
                DispatchQueue.main.async {
                    self.saveCredentials(updated)
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
            completion?(BridgeError.message("请先创建或加入同步集群"))
            return
        }
        let endpoints = knownEndpoints()
        guard !endpoints.isEmpty else {
            refreshPublishedState()
            completion?(BridgeError.message("尚无已配对节点，请先在另一台 Mac 使用配对码加入"))
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
        guard enabled else { return local }
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
        let freshest = statuses.max {
            ($0.1.usageFetchedAt ?? .distantPast) < ($1.1.usageFetchedAt ?? .distantPast)
        }?.1
        var value = freshest ?? AgentStatus()
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
            return current.code == join.code ? current : nil
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
                privateKey: state.privateKey, peerPublicKey: clientPublic, code: join.code
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
            clusterID: clusterID ?? "",
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
        guard enabled, let key = try? ClusterCrypto.clusterKey(lock.holding({ credentials })),
              let url = URL(string: endpoint + "/v2/cluster/manifest") else {
            completion?(BridgeError.message("同步配置无效")); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ClusterCrypto.signedHeaders(
            method: "GET", path: "/v2/cluster/manifest", body: Data(),
            nodeID: nodeID, key: key
        ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { completion?(BridgeError.message("同步服务已停止")); return }
            if let error { completion?(error); return }
            guard let http = response as? HTTPURLResponse else {
                completion?(BridgeError.message("节点 \(endpoint) 没有返回有效响应"))
                return
            }
            guard http.statusCode == 200 else {
                let message = http.statusCode == 401
                    ? "节点 \(endpoint) 尚未加入当前同步集群，请先使用配对码加入"
                    : "节点 \(endpoint) 返回 HTTP \(http.statusCode)"
                completion?(BridgeError.message(message))
                return
            }
            guard let data,
                  let (_, manifest) = try? ClusterCrypto.open(
                    ClusterManifest.self, data: data, key: key
                  ), manifest.protocolVersion == 2,
                  manifest.clusterID == self.clusterID else {
                completion?(BridgeError.message("节点 \(endpoint) 不属于当前同步集群"))
                return
            }
            guard manifest.senderNodeID != self.nodeID else {
                completion?(BridgeError.message("节点地址 \(endpoint) 指向本机"))
                return
            }
            let now = Date()
            self.lock.holding {
                for live in manifest.liveStatuses {
                    if self.liveStatuses[live.nodeID].map({ $0.observedAt >= live.observedAt }) == true {
                        continue
                    }
                    self.liveStatuses[live.nodeID] = live
                }
            }
            self.store.upsertClusterNode(ClusterNodeRecord(
                nodeID: manifest.senderNodeID,
                name: manifest.senderName,
                endpoint: endpoint,
                lastSeenAt: now,
                lastSyncAt: now
            ))
            for live in manifest.liveStatuses where live.nodeID != manifest.senderNodeID {
                self.store.upsertClusterNode(ClusterNodeRecord(
                    nodeID: live.nodeID,
                    name: live.nodeName,
                    endpoint: nil,
                    lastSeenAt: live.observedAt,
                    lastSyncAt: nil
                ))
            }
            let local = Dictionary(uniqueKeysWithValues: self.store.clusterManifest().map { ($0.key, $0) })
            let missing = manifest.snapshots.filter {
                guard let current = local[$0.key] else { return true }
                return $0.revision > current.revision
            }.map(\.key)
            if missing.isEmpty {
                DispatchQueue.main.async { self.refreshPublishedState() }
                completion?(nil)
                return
            }
            let pulls = DispatchGroup()
            for start in stride(from: 0, to: missing.count, by: 200) {
                let end = min(start + 200, missing.count)
                pulls.enter()
                self.pull(Array(missing[start..<end]), from: endpoint, key: key) {
                    pulls.leave()
                }
            }
            pulls.notify(queue: .main) { completion?(nil) }
        }.resume()
    }

    private func pull(_ keys: [ClusterSnapshotKey], from endpoint: String, key: SymmetricKey,
                      completion: (() -> Void)? = nil) {
        do {
            let body = try ClusterCrypto.seal(
                ClusterPullRequest(keys: keys), key: key, senderNodeID: nodeID
            )
            guard let url = URL(string: endpoint + "/v2/cluster/pull") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ClusterCrypto.signedHeaders(
                method: "POST", path: "/v2/cluster/pull", body: body,
                nodeID: nodeID, key: key
            ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            session.dataTask(with: request) { [weak self] data, response, _ in
                defer { completion?() }
                guard let self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let (_, pulled) = try? ClusterCrypto.open(
                        ClusterPullResponse.self, data: data, key: key
                      ) else { return }
                _ = self.store.mergeClusterSnapshots(pulled.snapshots)
                DispatchQueue.main.async { self.refreshPublishedState() }
            }.resume()
        } catch {
            setError(error.localizedDescription)
            completion?()
        }
    }

    private func scheduleAnnounce(_ descriptors: [ClusterSnapshotDescriptor]) {
        guard enabled, !descriptors.isEmpty else { return }
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
        let currentCluster = clusterID
        let discovered = discoveredPeers.filter {
            $0.clusterID == currentCluster && $0.nodeID != nodeID
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

    private func saveCredentials(_ value: ClusterCredentials) {
        do {
            try credentialStore.save(value)
            lock.holding { credentials = value }
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
        } catch { setError(error.localizedDescription) }
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
