import CryptoKit
import Security
import XCTest
@testable import ElinkAIBridge

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

        store.record(day: "2026-07-15", provider: "claude", models: ["opus": 10, "sonnet": 20])
        XCTAssertEqual(store.clusterManifest().first?.revision, 1)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15").count, 2)

        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 25])
        XCTAssertEqual(store.clusterManifest().first?.revision, 2)
        XCTAssertEqual(store.clusterUsage(provider: "claude", since: "2026-07-15"), [
            DailyModelUsage(
                day: "2026-07-15", provider: "claude", model: "sonnet",
                tokens: 25, nodeID: "node-a"
            ),
        ])

        store.record(day: "2026-07-15", provider: "claude", models: [:])
        XCTAssertEqual(store.clusterManifest().first?.revision, 3)
        XCTAssertTrue(store.clusterUsage(provider: "claude", since: "2026-07-15").isEmpty)
    }

    func testRemoteSnapshotsAreIdempotentAndOlderRevisionCannotOverwrite() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        let key = ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "codex")
        let current = ClusterUsageSnapshot(
            key: key, revision: 2, observedAt: Date(), models: ["gpt-5": 300]
        )
        XCTAssertEqual(store.mergeClusterSnapshots([current]).count, 1)
        XCTAssertTrue(store.mergeClusterSnapshots([current]).isEmpty)
        XCTAssertTrue(store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: key, revision: 1, observedAt: Date(), models: ["gpt-5": 999]
        )]).isEmpty)
        XCTAssertEqual(store.clusterUsage(provider: "codex", since: "2026-07-15").first?.tokens, 300)
    }

    func testResettingClusterDropsRemoteDataButPreservesLocalHistory() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.configureClusterStorage(nodeID: "node-a", nodeName: "Mac A", aggregationEnabled: true)
        store.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100])
        _ = store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(originNodeID: "node-b", day: "2026-07-15", provider: "claude"),
            revision: 1,
            observedAt: Date(),
            models: ["opus": 200]
        )])

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

    func testCredentialsFallBackWhenKeychainCannotInteractAndMigrateLater() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elink-credentials-\(UUID().uuidString)", isDirectory: true)
        let fallbackURL = directory.appendingPathComponent("credentials.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var keychainAvailable = false
        var keychainData: Data?
        let keychainRead: () throws -> Data = {
            guard keychainAvailable else {
                throw ClusterCryptoError.keychain(errSecInteractionNotAllowed)
            }
            guard let keychainData else { throw ClusterCryptoError.keychain(errSecItemNotFound) }
            return keychainData
        }
        let keychainWrite: (Data) throws -> Void = { data in
            guard keychainAvailable else {
                throw ClusterCryptoError.keychain(errSecInteractionNotAllowed)
            }
            keychainData = data
        }
        let store = ClusterCredentialStore(
            fallbackURL: fallbackURL,
            keychainRead: keychainRead,
            keychainWrite: keychainWrite
        )
        let expected = credentials(node: "fallback-node")

        XCTAssertNoThrow(try store.save(expected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: fallbackURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(store.loadOrCreate(), expected)

        keychainAvailable = true
        XCTAssertEqual(store.loadOrCreate(), expected)
        XCTAssertNotNil(keychainData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path))
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

        XCTAssertEqual(receivedError?.localizedDescription, "请输入有效的节点地址和 6 位配对码")
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
        storeA.record(day: "2026-07-15", provider: "claude", models: ["sonnet": 100])

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
        XCTAssertEqual(storeB.mergeClusterSnapshots(pulled.snapshots).count, 1)
        XCTAssertTrue(storeB.mergeClusterSnapshots(pulled.snapshots).isEmpty)
        XCTAssertEqual(storeB.clusterUsage(provider: "claude", since: "2026-07-15").first?.tokens, 100)
    }

    func testOfflineNodeContributionRemainsInAggregate() {
        let secret = Data(repeating: 5, count: 32)
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ClusterManager(store: store, credentials: credentials(node: "node-a", secret: secret))
        store.record(day: StatusService.dayKey(Date()), provider: "claude", models: ["sonnet": 100])
        _ = store.mergeClusterSnapshots([ClusterUsageSnapshot(
            key: ClusterSnapshotKey(
                originNodeID: "node-b", day: StatusService.dayKey(Date()), provider: "claude"
            ),
            revision: 1,
            observedAt: Date().addingTimeInterval(-3600),
            models: ["opus": 250]
        )])
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
}
