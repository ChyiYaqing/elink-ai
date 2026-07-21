import CryptoKit
import XCTest
@testable import ElinkAIBridge

private final class JoinURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? BridgeError.message("failed to read request body")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw BridgeError.message("missing URL protocol handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ClusterTests: XCTestCase {
    private func store(_ name: String = UUID().uuidString) -> (UsageStore, String) {
        let path = NSTemporaryDirectory() + "elink-cluster-\(name).db"
        try? FileManager.default.removeItem(atPath: path)
        return (UsageStore(path: path), path)
    }

    private func credentials(node: String, secret: Data = Data(repeating: 7, count: 32)) -> ClusterCredentials {
        ClusterCredentials(
            nodeID: node,
            nodeName: "Mac \(node)",
            clusterID: "cluster-test",
            clusterSecret: secret.base64EncodedString(),
            timezone: "Asia/Singapore"
        )
    }

    func testLocalClusterSnapshotReplacesCompleteModelSetAndIncrementsRevision() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)

        store.record(day: "2026-07-15", provider: "claude",
                     models: ["opus": 10, "sonnet": 20], expectedBucketTimeZone: nil)
        XCTAssertEqual(store.clusterManifest().first?.revision, 1)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15").count, 2)

        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 25],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.clusterManifest().first?.revision, 2)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15"), [
            DailyModelUsage(
                day: "2026-07-15", provider: "claude", model: "sonnet",
                tokens: 25, nodeID: "node-a"
            ),
        ])

        // 空集来自暂时读不到日志的场景，不能清掉已有快照或推高 revision
        store.record(day: "2026-07-15", provider: "claude", models: [:],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.clusterManifest().first?.revision, 2)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15").first?.tokens, 25)
    }

    func testLiveRecordPreservesResidueFromDeletedLogs() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: false)
        store.record(day: "2026-07-15", provider: "claude",
                     models: ["opus": 10, "sonnet": 20], expectedBucketTimeZone: nil,
                     preservingResidue: true)

        // 当日部分日志被删后重算变小：opus 整体消失、sonnet 缩水，二者都按残差保留
        store.record(day: "2026-07-15", provider: "claude",
                     models: ["sonnet": 15], expectedBucketTimeZone: nil,
                     preservingResidue: true)

        let rows = store.usage(provider: "claude", since: "2026-07-15")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.model, $0.tokens) }),
            ["opus": 10, "sonnet": 20]
        )
    }

    func testRemoteSnapshotsAreIdempotentAndOlderRevisionCannotOverwrite() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        let key = ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "codex")
        let current = ClusterUsageSnapshot(
            key: key, revision: 2, observedAt: Date(), models: ["gpt-5": 300]
        )
        XCTAssertEqual(store.mergeClusterSnapshots(
            [current], ifEpoch: store.clusterDataEpoch()
        )?.count, 1)
        XCTAssertEqual(store.mergeClusterSnapshots(
            [current], ifEpoch: store.clusterDataEpoch()
        )?.isEmpty, true)
        XCTAssertEqual(store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: key, revision: 1, observedAt: Date(), models: ["gpt-5": 999]
        )], ifEpoch: store.clusterDataEpoch())?.isEmpty, true)
        XCTAssertEqual(store.clusterUsage(provider: "codex", since: "2026-07-15").first?.tokens, 300)
    }

    func testRemoteSnapshotClaimingLocalOriginIsRejected() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: nil)

        let forged = ClusterUsageSnapshot(
            key: ClusterSnapshotKey(originNodeID: "node-a", day: "2026-07-15", provider: "claude"),
            revision: 999,
            observedAt: Date(),
            models: ["sonnet": 1]
        )
        XCTAssertEqual(store.mergeClusterSnapshots(
            [forged], ifEpoch: store.clusterDataEpoch()
        )?.isEmpty, true)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15").first?.tokens, 100)
        XCTAssertEqual(store.clusterManifest().first?.revision, 1)
    }

    func testResettingClusterDropsRemoteDataButPreservesLocalHistory() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: nil)
        _ = store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "claude"),
            revision: 1,
            observedAt: Date(),
            models: ["opus": 200]
        )], ifEpoch: store.clusterDataEpoch())

        store.resetRemoteClusterData(localNodeID: "node-a")

        let rows = store.clusterUsage(provider: "claude", since: "2026-07-15")
        XCTAssertEqual(rows.map(\.nodeID), ["node-a"])
        XCTAssertEqual(rows.first?.tokens, 100)
        XCTAssertEqual(store.clusterManifest().map(\.key.originNodeID), ["node-a"])
    }

    func testClusterCryptoEncryptsAuthenticatesAndRejectsTampering() throws {
        let credentials = credentials(node: "node-a")
        let key = try ClusterCrypto.clusterKey(credentials)
        let payload = ClusterPullRequest(keys: [
            ClusterSnapshotKey(originNodeID: "node-a", day: "2026-07-15", provider: "claude"),
        ])
        let body = try ClusterCrypto.seal(payload, key: key, senderNodeID: "node-a")
        let opened = try ClusterCrypto.open(ClusterPullRequest.self, data: body, key: key)
        XCTAssertEqual(opened.0, "node-a")
        XCTAssertEqual(opened.1.keys, payload.keys)

        let headers = ClusterCrypto.signedHeaders(
            method: "POST", path: "/v2/cluster/pull", body: body,
            nodeID: "node-a", key: key, now: Date(timeIntervalSince1970: 1000), nonce: "nonce"
        )
        let lowercased = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        XCTAssertNotNil(ClusterCrypto.verify(
            method: "POST", path: "/v2/cluster/pull", body: body,
            headers: lowercased, key: key, now: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertNil(ClusterCrypto.verify(
            method: "POST", path: "/v2/cluster/pull", body: body + Data([0]),
            headers: lowercased, key: key, now: Date(timeIntervalSince1970: 1000)
        ))
    }

    func testCredentialsPersistInSQLiteAndMigrateLegacyFallback() throws {
        let (usageStore, databasePath) = store()
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elink-credentials-\(UUID().uuidString)", isDirectory: true)
        let fallbackURL = directory.appendingPathComponent("credentials.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = credentials(node: "fallback-node")
        try ClusterCrypto.encoder.encode(expected).write(to: fallbackURL)
        let credentialStore = ClusterCredentialStore(
            store: usageStore, legacyFallbackURL: fallbackURL
        )

        XCTAssertEqual(credentialStore.loadOrCreate(), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path))
        XCTAssertEqual(credentialStore.loadOrCreate(), expected)

        let replacement = credentials(node: "sqlite-node", secret: Data(repeating: 8, count: 32))
        try credentialStore.save(replacement)
        XCTAssertEqual(credentialStore.loadOrCreate(), replacement)
        let attributes = try FileManager.default.attributesOfItem(atPath: databasePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testJoiningClusterReportsMissingPairingCodeInsteadOfDoingNothing() {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ClusterManager(store: usageStore, credentials: ClusterCredentials(
            nodeID: "standalone-node",
            nodeName: "Standalone Mac",
            clusterID: nil,
            clusterSecret: nil,
            timezone: nil
        ))
        var receivedError: Error?

        manager.joinCluster(endpoint: "10.1.7.106:8765", code: "") {
            receivedError = $0
        }

        XCTAssertEqual(receivedError?.localizedDescription, "请输入有效的节点地址和 16 位配对码")
    }

    func testStaleJoinResponseCannotOverwriteNewlyCreatedCluster() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JoinURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            JoinURLProtocolStub.handler = nil
            session.invalidateAndCancel()
        }
        let manager = ClusterManager(
            store: usageStore,
            credentials: ClusterCredentials(
                nodeID: "standalone-node", nodeName: "Standalone Mac",
                clusterID: nil, clusterSecret: nil, timezone: nil
            ),
            session: session
        )
        let code = ClusterCrypto.generatePairingCode()
        let requestStarted = expectation(description: "join request started")
        let allowResponse = DispatchSemaphore(value: 0)
        JoinURLProtocolStub.handler = { request in
            guard request.url?.path == "/v3/cluster/pair/join" else {
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: try XCTUnwrap(request.url), statusCode: 404,
                        httpVersion: nil, headerFields: nil
                    )),
                    Data()
                )
            }
            requestStarted.fulfill()
            allowResponse.wait()
            let join = try ClusterCrypto.decoder.decode(
                ClusterJoinRequest.self, from: try JoinURLProtocolStub.bodyData(for: request)
            )
            let clientPublic = try XCTUnwrap(Data(base64Encoded: join.clientPublicKey))
            let serverPrivate = Curve25519.KeyAgreement.PrivateKey()
            let key = try ClusterCrypto.pairingKey(
                privateKey: serverPrivate, peerPublicKey: clientPublic, code: code
            )
            let sealed = try ClusterCrypto.seal(
                ClusterJoinSecret(
                    clusterID: "stale-remote-cluster",
                    clusterSecret: Data(repeating: 3, count: 32).base64EncodedString(),
                    timezone: "UTC"
                ),
                key: key,
                senderNodeID: "remote-node"
            )
            let body = try ClusterCrypto.encoder.encode(ClusterJoinResponse(
                serverPublicKey: serverPrivate.publicKey.rawRepresentation.base64EncodedString(),
                sealed: sealed.base64EncodedString()
            ))
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )),
                body
            )
        }

        let completed = expectation(description: "join completed")
        var joinError: Error?
        manager.joinCluster(endpoint: "pairing.test:8765", code: code) {
            joinError = $0
            completed.fulfill()
        }
        wait(for: [requestStarted], timeout: 2)
        XCTAssertTrue(manager.createCluster())
        let newClusterID = try XCTUnwrap(manager.clusterID)

        allowResponse.signal()
        wait(for: [completed], timeout: 2)

        XCTAssertEqual(manager.clusterID, newClusterID)
        XCTAssertEqual(joinError?.localizedDescription, "配对已取消：集群配置已变化")
    }

    func testPairingCodeGenerationAndNormalization() {
        let code = ClusterCrypto.generatePairingCode()
        XCTAssertEqual(code.count, ClusterCrypto.pairingCodeLength)
        XCTAssertNotEqual(code, ClusterCrypto.generatePairingCode())

        let formatted = ClusterCrypto.formattedPairingCode(code)
        XCTAssertEqual(formatted.count, 19)
        XCTAssertEqual(ClusterCrypto.normalizedPairingCode(formatted), code)
        XCTAssertEqual(ClusterCrypto.normalizedPairingCode(code.lowercased()), code)
        XCTAssertNil(ClusterCrypto.normalizedPairingCode("123456"))
        XCTAssertNil(ClusterCrypto.normalizedPairingCode(""))
    }

    func testDiscoverySameMachineGuardRejectsLocalAndLoopbackPeers() {
        let local: Set<String> = ["192.168.1.5", "fe80::1"]
        // A co-located bridge advertising this machine's LAN address.
        XCTAssertTrue(ClusterDiscovery.isColocated(
            peerAddresses: ["192.168.1.5"], localAddresses: local
        ))
        // Loopback is always same-machine, even if absent from the interface set.
        XCTAssertTrue(ClusterDiscovery.isColocated(
            peerAddresses: ["127.0.0.1"], localAddresses: local
        ))
        XCTAssertTrue(ClusterDiscovery.isColocated(
            peerAddresses: ["::1"], localAddresses: local
        ))
        // A genuine remote peer shares no address with us.
        XCTAssertFalse(ClusterDiscovery.isColocated(
            peerAddresses: ["192.168.1.9"], localAddresses: local
        ))
        // IPv6 zone ids are stripped before comparison.
        XCTAssertEqual(ClusterDiscovery.normalizeIP("FE80::1%en0"), "fe80::1")
    }

    func testPairingHandshakeDeliversSecretWithoutSendingCodeOnWire() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let host = ClusterManager(store: usageStore, credentials: credentials(node: "host-node"))
        let formattedCode = try XCTUnwrap(host.startPairing())
        let code = try XCTUnwrap(ClusterCrypto.normalizedPairingCode(formattedCode))

        let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
        let clientPublic = clientPrivate.publicKey.rawRepresentation
        let join = ClusterJoinRequest(
            proof: ClusterCrypto.pairingProof(
                code: code, clientPublicKey: clientPublic, clientNodeID: "client-node"
            ),
            clientNodeID: "client-node",
            clientName: "Client Mac",
            clientPublicKey: clientPublic.base64EncodedString()
        )
        let body = try ClusterCrypto.encoder.encode(join)
        // 配对码绝不能出现在网线上的任何字节里
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(code))

        let route = try XCTUnwrap(host.routes()[HTTPRouteKey("POST", "/v3/cluster/pair/join")])
        let response = route(HTTPRequest(
            method: "POST", path: "/v3/cluster/pair/join", query: [:],
            headers: [:], body: body, peer: "127.0.0.1"
        ))
        XCTAssertEqual(response.status, 200)

        let joined = try ClusterCrypto.decoder.decode(ClusterJoinResponse.self, from: response.body)
        let serverPublic = try XCTUnwrap(Data(base64Encoded: joined.serverPublicKey))
        let key = try ClusterCrypto.pairingKey(
            privateKey: clientPrivate, peerPublicKey: serverPublic, code: code
        )
        let sealed = try XCTUnwrap(Data(base64Encoded: joined.sealed))
        let (_, secret) = try ClusterCrypto.open(ClusterJoinSecret.self, data: sealed, key: key)
        XCTAssertEqual(secret.clusterID, "cluster-test")
        XCTAssertEqual(secret.timezone, "Asia/Singapore")

        // 旧版 v2 配对端点必须返回明确的协议升级错误，而不是笼统的解码失败
        let legacyRoute = try XCTUnwrap(host.routes()[HTTPRouteKey("POST", "/v2/cluster/pair/join")])
        XCTAssertEqual(legacyRoute(HTTPRequest(
            method: "POST", path: "/v2/cluster/pair/join", query: [:],
            headers: [:], body: body, peer: "127.0.0.1"
        )).status, 426)
    }

    func testPairingRejectsWrongCodeProof() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let host = ClusterManager(store: usageStore, credentials: credentials(node: "host-node"))
        XCTAssertNotNil(host.startPairing())

        let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
        let clientPublic = clientPrivate.publicKey.rawRepresentation
        let join = ClusterJoinRequest(
            proof: ClusterCrypto.pairingProof(
                code: ClusterCrypto.generatePairingCode(),
                clientPublicKey: clientPublic,
                clientNodeID: "client-node"
            ),
            clientNodeID: "client-node",
            clientName: "Client Mac",
            clientPublicKey: clientPublic.base64EncodedString()
        )
        let route = try XCTUnwrap(host.routes()[HTTPRouteKey("POST", "/v3/cluster/pair/join")])
        let response = route(HTTPRequest(
            method: "POST", path: "/v3/cluster/pair/join", query: [:],
            headers: [:], body: try ClusterCrypto.encoder.encode(join), peer: "127.0.0.1"
        ))
        XCTAssertEqual(response.status, 403)
    }

    func testLocalDailyOverwriteDeletesAbsentModels() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: false)

        store.record(day: "2026-07-15", provider: "claude",
                     models: ["opus": 10, "sonnet": 20], expectedBucketTimeZone: nil)
        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 25],
                     expectedBucketTimeZone: nil)

        // 非集群读取路径走 daily_model_usage 表，消失的 opus 不应残留
        let rows = store.usage(provider: "claude", since: "2026-07-15")
        XCTAssertEqual(rows.map(\.model), ["sonnet"])
        XCTAssertEqual(rows.first?.tokens, 25)
    }

    func testClearLocalDayRemovesRowsAndPublishesEmptySnapshot() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // aggregation 关闭时 usage() 走本地 daily 表，可直接验证行被删除
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: false)
        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: nil)
        XCTAssertEqual(store.clusterManifest().first?.revision, 1)

        store.clearLocalDay(day: "2026-07-15", provider: "claude")

        XCTAssertTrue(store.usage(provider: "claude", since: "2026-07-15").isEmpty)
        XCTAssertTrue(store.clusterUsage(provider: "claude", since: "2026-07-15").isEmpty)
        // 空快照必须递增 revision，才能把“清空”同步给对端
        XCTAssertEqual(store.clusterManifest().first?.revision, 2)
    }

    func testMergeClusterSnapshotsRejectsStaleEpoch() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        let snapshot = ClusterUsageSnapshot(
            key: ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "claude"),
            revision: 1,
            observedAt: Date(),
            models: ["opus": 200]
        )
        let epoch = store.clusterDataEpoch()
        store.resetRemoteClusterData(localNodeID: "node-a")

        // 携带 reset 前纪元的在途回包必须被整体拒绝：返回 nil 而非“无新数据”的空数组
        XCTAssertNil(store.mergeClusterSnapshots([snapshot], ifEpoch: epoch))
        XCTAssertTrue(store.clusterUsage(provider: "claude", since: "2026-07-15").isEmpty)
        XCTAssertEqual(store.mergeClusterSnapshots([snapshot],
                                                   ifEpoch: store.clusterDataEpoch())?.count, 1)
    }

    func testRemoteNodeUpsertReportsStaleEpoch() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        let staleEpoch = store.clusterDataEpoch()
        store.resetRemoteClusterData(localNodeID: "node-a")
        let remote = ClusterNodeRecord(
            nodeID: "node-b", name: "Mac B", endpoint: "http://node-b:8765",
            lastSeenAt: Date(), lastSyncAt: Date()
        )

        XCTAssertFalse(store.upsertRemoteClusterNode(remote, ifEpoch: staleEpoch))
        XCTAssertFalse(store.clusterNodes().contains { $0.nodeID == "node-b" })
        XCTAssertTrue(store.upsertRemoteClusterNode(remote, ifEpoch: store.clusterDataEpoch()))
        XCTAssertTrue(store.clusterNodes().contains { $0.nodeID == "node-b" })
    }

    func testSavingCredentialsAtomicallyResetsRemoteDataAndBumpsEpoch() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        usageStore.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        usageStore.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                          expectedBucketTimeZone: nil)
        _ = usageStore.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "claude"),
            revision: 1,
            observedAt: Date(),
            models: ["opus": 200]
        )], ifEpoch: usageStore.clusterDataEpoch())
        let credentialStore = ClusterCredentialStore(store: usageStore)
        let epochBefore = usageStore.clusterDataEpoch()

        // 换凭据 + 清旧集群数据必须一次完成：新密钥绝不能配旧集群快照
        try credentialStore.save(credentials(node: "node-a"), resettingRemoteDataExcept: "node-a")

        XCTAssertGreaterThan(usageStore.clusterDataEpoch(), epochBefore)
        XCTAssertEqual(usageStore.clusterManifest().map(\.key.originNodeID), ["node-a"])
        XCTAssertEqual(credentialStore.loadOrCreate(), credentials(node: "node-a"))
        XCTAssertEqual(usageStore.clusterUsage(provider: "claude", since: "2026-07-15").map(\.nodeID),
                       ["node-a"])
    }

    func testSignedManifestPullConvergesTwoStoresWithoutDoubleCounting() throws {
        let secret = Data(repeating: 9, count: 32)
        let (storeA, pathA) = store("a-\(UUID().uuidString)")
        let (storeB, pathB) = store("b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: pathA)
            try? FileManager.default.removeItem(atPath: pathB)
        }
        let credentialsA = credentials(node: "node-a", secret: secret)
        let credentialsB = credentials(node: "node-b", secret: secret)
        let managerA = ClusterManager(store: storeA, credentials: credentialsA)
        _ = ClusterManager(store: storeB, credentials: credentialsB)
        managerA.localStatusProvider = { BridgeSnapshot() }
        storeA.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100],
                      expectedBucketTimeZone: nil)

        let key = try ClusterCrypto.clusterKey(credentialsB)
        let manifestHeaders = ClusterCrypto.signedHeaders(
            method: "GET", path: "/v2/cluster/manifest", body: Data(),
            nodeID: "node-b", key: key
        )
        let manifestRequest = HTTPRequest(
            method: "GET",
            path: "/v2/cluster/manifest",
            query: [:],
            headers: Dictionary(uniqueKeysWithValues: manifestHeaders.map { ($0.key.lowercased(), $0.value) }),
            body: Data(),
            peer: "127.0.0.1"
        )
        let manifestRoute = try XCTUnwrap(managerA.routes()[HTTPRouteKey("GET", "/v2/cluster/manifest")])
        let manifestResponse = manifestRoute(manifestRequest)
        XCTAssertEqual(manifestResponse.status, 200)
        let (_, manifest) = try ClusterCrypto.open(
            ClusterManifest.self, data: manifestResponse.body, key: key
        )
        XCTAssertEqual(manifest.snapshots.count, 1)

        let pullBody = try ClusterCrypto.seal(
            ClusterPullRequest(keys: manifest.snapshots.map(\.key)),
            key: key,
            senderNodeID: "node-b"
        )
        let pullHeaders = ClusterCrypto.signedHeaders(
            method: "POST", path: "/v2/cluster/pull", body: pullBody,
            nodeID: "node-b", key: key
        )
        let pullRequest = HTTPRequest(
            method: "POST",
            path: "/v2/cluster/pull",
            query: [:],
            headers: Dictionary(uniqueKeysWithValues: pullHeaders.map { ($0.key.lowercased(), $0.value) }),
            body: pullBody,
            peer: "127.0.0.1"
        )
        let pullRoute = try XCTUnwrap(managerA.routes()[HTTPRouteKey("POST", "/v2/cluster/pull")])
        let pullResponse = pullRoute(pullRequest)
        XCTAssertEqual(pullResponse.status, 200)
        let (_, pulled) = try ClusterCrypto.open(
            ClusterPullResponse.self, data: pullResponse.body, key: key
        )
        XCTAssertEqual(storeB.mergeClusterSnapshots(
            pulled.snapshots, ifEpoch: storeB.clusterDataEpoch()
        )?.count, 1)
        XCTAssertEqual(storeB.mergeClusterSnapshots(
            pulled.snapshots, ifEpoch: storeB.clusterDataEpoch()
        )?.isEmpty, true)
        XCTAssertEqual(storeB.clusterUsage(provider: "claude", since: "2026-07-15").first?.tokens, 100)
    }

    func testOfflineNodeContributionRemainsInAggregate() {
        let secret = Data(repeating: 5, count: 32)
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ClusterManager(store: store, credentials: credentials(node: "node-a", secret: secret))
        store.record(day: StatusService.dayKey(Date()), provider: "claude", models: ["sonnet": 100],
                     expectedBucketTimeZone: nil)
        _ = store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(
                originNodeID: "node-b", day: StatusService.dayKey(Date()), provider: "claude"
            ),
            revision: 1,
            observedAt: Date().addingTimeInterval(-3600),
            models: ["opus": 250]
        )], ifEpoch: store.clusterDataEpoch())
        store.upsertClusterNode(ClusterNodeRecord(
            nodeID: "node-b", name: "Offline Mac", endpoint: nil,
            lastSeenAt: Date().addingTimeInterval(-3600), lastSyncAt: Date().addingTimeInterval(-3600)
        ))

        let aggregate = manager.aggregate(local: BridgeSnapshot())
        XCTAssertEqual(aggregate.claude.tokensToday, 350)
        XCTAssertEqual(aggregate.claude.modelUsageToday, [
            ModelUsage(model: "opus", tokens: 250),
            ModelUsage(model: "sonnet", tokens: 100),
        ])
        XCTAssertEqual(aggregate.cluster.nodeCount, 2)
        XCTAssertEqual(aggregate.cluster.onlineCount, 1)
    }

    func testAggregatePrefersRecentErrorFreeUsageStatus() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let limited = AgentStatus(
            primary: UsageWindow(percent: 102),
            error: "Claude 用量 HTTP 429",
            usageFetchedAt: now
        )
        let successful = AgentStatus(
            primary: UsageWindow(percent: 98),
            usageFetchedAt: now.addingTimeInterval(-300)
        )

        let preferred = try XCTUnwrap(ClusterManager.preferredUsageStatus(
            [(now, limited), (now, successful)],
            now: now
        ))

        XCTAssertEqual(preferred.primary.percent, 98)
        XCTAssertNil(preferred.error)
    }

    func testAggregateDoesNotReplaceFreshLimitedUsageWithStaleSuccess() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let limited = AgentStatus(
            primary: UsageWindow(percent: 102),
            error: "Claude 用量 HTTP 429",
            usageFetchedAt: now
        )
        let staleSuccess = AgentStatus(
            primary: UsageWindow(percent: 72),
            usageFetchedAt: now.addingTimeInterval(-1_200)
        )

        let preferred = try XCTUnwrap(ClusterManager.preferredUsageStatus(
            [(now, limited), (now, staleSuccess)],
            now: now
        ))

        XCTAssertEqual(preferred.primary.percent, 102)
        XCTAssertEqual(preferred.error, "Claude 用量 HTTP 429")
    }
}
