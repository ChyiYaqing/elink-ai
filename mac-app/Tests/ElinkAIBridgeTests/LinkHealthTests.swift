import XCTest
@testable import ElinkAIBridge

private final class ProbeURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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

final class LinkHealthTests: XCTestCase {
    // 断言依赖中文文案；语言默认跟随系统，这里固定为中文保证在英文系统的 CI 上稳定
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    private func store(_ name: String = UUID().uuidString) -> (UsageStore, String) {
        let path = NSTemporaryDirectory() + "elink-link-\(name).db"
        try? FileManager.default.removeItem(atPath: path)
        return (UsageStore(path: path), path)
    }

    /// base 落在 [1_699_999_800, 1_700_000_100) 这个桶内；+400 落入 1_700_000_400 桶
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testSamplesAggregateIntoAlignedFiveMinuteBuckets() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "n1", at: base, rttMs: 210)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(50), rttMs: 190)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(400), rttMs: 700)

        let rows = store.linkBuckets(since: base.addingTimeInterval(-600))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bucketAt, Date(timeIntervalSince1970: 1_699_999_800))
        XCTAssertEqual(rows[0].samples, 2)
        XCTAssertEqual(rows[0].okSamples, 2)
        XCTAssertEqual(rows[0].rttMinMs, 190)
        XCTAssertEqual(rows[0].rttMaxMs, 210)
        XCTAssertEqual(rows[0].rttAvgMs, 200)
        XCTAssertEqual(rows[1].bucketAt, Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertEqual(rows[1].samples, 1)
        XCTAssertEqual(rows[1].rttMaxMs, 700)
    }

    /// 全部失败的桶必须保留 nil 而不是 0，否则图上会画出一条 0ms 的假线
    func testFullyFailedBucketKeepsNilLatencyAndCountsLostSamples() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "n1", at: base, rttMs: nil)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(30), rttMs: nil)

        let rows = store.linkBuckets(since: base.addingTimeInterval(-600))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].samples, 2)
        XCTAssertEqual(rows[0].okSamples, 0)
        XCTAssertNil(rows[0].rttMinMs)
        XCTAssertNil(rows[0].rttMaxMs)
        XCTAssertNil(rows[0].rttAvgMs)
    }

    /// 失败样本不能污染 min/max：两个方向都要覆盖，COALESCE 写反时只有一侧会错
    func testFailedSamplesDoNotAffectLatencyBoundsInEitherOrder() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "fail-first", at: base, rttMs: nil)
        store.recordLinkSample(nodeID: "fail-first", at: base.addingTimeInterval(15), rttMs: 205)

        store.recordLinkSample(nodeID: "ok-first", at: base, rttMs: 205)
        store.recordLinkSample(nodeID: "ok-first", at: base.addingTimeInterval(15), rttMs: nil)

        let failFirst = store.linkBuckets(since: base.addingTimeInterval(-600), nodeID: "fail-first")
        XCTAssertEqual(failFirst.count, 1)
        XCTAssertEqual(failFirst[0].samples, 2)
        XCTAssertEqual(failFirst[0].okSamples, 1)
        XCTAssertEqual(failFirst[0].rttMinMs, 205)
        XCTAssertEqual(failFirst[0].rttMaxMs, 205)
        XCTAssertEqual(failFirst[0].rttAvgMs, 205)

        let okFirst = store.linkBuckets(since: base.addingTimeInterval(-600), nodeID: "ok-first")
        XCTAssertEqual(okFirst.count, 1)
        XCTAssertEqual(okFirst[0].samples, 2)
        XCTAssertEqual(okFirst[0].okSamples, 1)
        XCTAssertEqual(okFirst[0].rttMinMs, 205)
        XCTAssertEqual(okFirst[0].rttMaxMs, 205)
        XCTAssertEqual(okFirst[0].rttAvgMs, 205)
    }

    func testBucketsAreFilteredByNodeAndStartTime() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "n1", at: base, rttMs: 100)
        store.recordLinkSample(nodeID: "n2", at: base, rttMs: 100)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(-3600), rttMs: 100)

        XCTAssertEqual(store.linkBuckets(since: base.addingTimeInterval(-7200)).count, 3)
        XCTAssertEqual(store.linkBuckets(since: base.addingTimeInterval(-600)).count, 2)
        XCTAssertEqual(
            store.linkBuckets(since: base.addingTimeInterval(-600), nodeID: "n1").count, 1
        )
    }

    func testEmptyNodeIDIsIgnored() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "", at: base, rttMs: 100)
        XCTAssertTrue(store.linkBuckets(since: base.addingTimeInterval(-600)).isEmpty)
    }

    func testEventsReadBackNewestFirstAndRespectLimit() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkEvent(LinkEvent(
            occurredAt: base, nodeID: "n1", kind: .offline, detail: "http://host:8765"
        ))
        store.recordLinkEvent(LinkEvent(
            occurredAt: base.addingTimeInterval(60), nodeID: "n1", kind: .online, detail: nil
        ))

        let events = store.linkEvents(since: base.addingTimeInterval(-600))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .online)
        XCTAssertNil(events[0].detail)
        XCTAssertEqual(events[1].kind, .offline)
        XCTAssertEqual(events[1].detail, "http://host:8765")

        XCTAssertEqual(store.linkEvents(since: base.addingTimeInterval(-600), limit: 1).count, 1)
        XCTAssertTrue(store.linkEvents(since: base.addingTimeInterval(600)).isEmpty)
    }

    /// 旧库升级后两张表为空，读取路径不能崩
    func testFreshDatabaseReturnsEmptyHistory() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(store.linkBuckets(since: Date(timeIntervalSince1970: 0)).isEmpty)
        XCTAssertTrue(store.linkEvents(since: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    // MARK: - 汇总与呈现

    func testAggregatesMergeBucketsPerNodeAndComputeLoss() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkSample(nodeID: "n1", at: base, rttMs: 200)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(400), rttMs: 240)
        store.recordLinkSample(nodeID: "n1", at: base.addingTimeInterval(410), rttMs: nil)
        store.recordLinkSample(nodeID: "n2", at: base, rttMs: 5)

        let aggregates = store.linkAggregates(since: base.addingTimeInterval(-600))
        let first = try? XCTUnwrap(aggregates["n1"])
        XCTAssertEqual(first?.samples, 3)
        XCTAssertEqual(first?.okSamples, 2)
        XCTAssertEqual(first?.rttMinMs, 200)
        XCTAssertEqual(first?.rttMaxMs, 240)
        XCTAssertEqual(first?.rttAvgMs, 220)
        XCTAssertEqual(first?.lostSamples, 1)
        XCTAssertEqual(first?.lostPercent, 33.3)
        XCTAssertEqual(aggregates["n2"]?.samples, 1)
        XCTAssertNil(aggregates["missing"])
    }

    /// 健康的行保持安静，只有真的丢样才追加提示
    func testLinkDetailTextOnlyMentionsLossWhenSamplesWereLost() {
        let healthy = LinkAggregate(samples: 240, okSamples: 240, rttMinMs: 203,
                                    rttMaxMs: 228, rttSumMs: 240 * 215)
        XCTAssertEqual(UsagePanelView.clusterLinkDetail(healthy), "203/215/228ms · 240 次采样")

        let lossy = LinkAggregate(samples: 240, okSamples: 236, rttMinMs: 203,
                                  rttMaxMs: 228, rttSumMs: 236 * 215)
        XCTAssertEqual(UsagePanelView.clusterLinkDetail(lossy), "203/215/228ms · 4/240 丢样")

        let dead = LinkAggregate(samples: 240, okSamples: 0, rttMinMs: nil,
                                 rttMaxMs: nil, rttSumMs: 0)
        XCTAssertEqual(UsagePanelView.clusterLinkDetail(dead), "无响应 · 240/240 丢样")
    }

    /// 链路字段随节点名进 /v1/status，endpoint 必须留在本机
    func testStatusJSONCarriesLinkSummaryWithoutAddresses() throws {
        var snapshot = BridgeSnapshot()
        snapshot.cluster = ClusterSummary(
            enabled: true, nodeCount: 2, onlineCount: 2, lastSyncedAt: base,
            link: [ClusterLinkSummary(node: "Studio", rttAvgMs: 215,
                                      lostPct: 1.7, samples: 240)]
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any]
        )
        let cluster = try XCTUnwrap(object["cluster"] as? [String: Any])
        let link = try XCTUnwrap(cluster["link"] as? [[String: Any]])
        XCTAssertEqual(link.count, 1)
        XCTAssertEqual(link[0]["node"] as? String, "Studio")
        XCTAssertEqual(link[0]["rtt_avg_ms"] as? Int, 215)
        XCTAssertEqual(link[0]["samples"] as? Int, 240)
        let encoded = String(decoding: snapshot.jsonData(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("http://"))
        XCTAssertFalse(encoded.contains("endpoint"))
    }

    // MARK: - 探测接入

    /// 401 说明对端在线只是没入群，必须记成可达；否则配置问题会显示成网络故障
    func testHTTPErrorResponseCountsAsReachableWhileNetworkFailureDoesNot() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProbeURLProtocolStub.handler = nil
            session.invalidateAndCancel()
        }

        let endpoint = "http://peer.invalid:8765"
        XCTAssertTrue(usageStore.upsertRemoteClusterNode(
            ClusterNodeRecord(nodeID: "peer-1", name: "Peer", endpoint: endpoint,
                              lastSeenAt: nil, lastSyncAt: nil),
            ifEpoch: usageStore.clusterDataEpoch()
        ))
        let manager = ClusterManager(
            store: usageStore,
            credentials: ClusterCredentials(
                nodeID: "local-node", nodeName: "Local Mac", clusterID: "cluster-test",
                clusterSecret: Data(repeating: 7, count: 32).base64EncodedString(),
                timezone: "Asia/Singapore"
            ),
            session: session
        )
        let since = Date().addingTimeInterval(-600)

        ProbeURLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                           httpVersion: nil, headerFields: nil)), Data())
        }
        let reachablePass = expectation(description: "sync with HTTP 401")
        manager.syncAll { _ in reachablePass.fulfill() }
        wait(for: [reachablePass], timeout: 10)

        var rows = usageStore.linkBuckets(since: since, nodeID: "peer-1")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.samples }, 1)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.okSamples }, 1)
        XCTAssertNotNil(rows.compactMap(\.rttMinMs).first)
        // 首次观测不是跃迁，不应写事件
        XCTAssertTrue(usageStore.linkEvents(since: since).isEmpty)

        ProbeURLProtocolStub.handler = { _ in
            throw BridgeError.message("connection refused")
        }
        let failingPass = expectation(description: "sync with transport failure")
        manager.syncAll { _ in failingPass.fulfill() }
        wait(for: [failingPass], timeout: 10)

        rows = usageStore.linkBuckets(since: since, nodeID: "peer-1")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.samples }, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.okSamples }, 1)

        let events = usageStore.linkEvents(since: since)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .offline)
        XCTAssertEqual(events[0].nodeID, "peer-1")
        XCTAssertEqual(events[0].detail, endpoint)
    }

    /// endpoint 尚未归属到任何已知节点时不能记录，否则样本会挂到错误的主体上
    func testProbeIsSkippedForEndpointWithoutKnownNode() throws {
        let (usageStore, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProbeURLProtocolStub.handler = nil
            session.invalidateAndCancel()
        }
        ProbeURLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                           httpVersion: nil, headerFields: nil)), Data())
        }

        let manager = ClusterManager(
            store: usageStore,
            credentials: ClusterCredentials(
                nodeID: "local-node", nodeName: "Local Mac", clusterID: "cluster-test",
                clusterSecret: Data(repeating: 7, count: 32).base64EncodedString(),
                timezone: "Asia/Singapore"
            ),
            session: session
        )
        manager.addManualEndpoint("http://unknown.invalid:8765")
        defer { UserDefaults.standard.removeObject(forKey: "elink_cluster_manual_peers_v2") }
        let since = Date().addingTimeInterval(-600)
        let pass = expectation(description: "sync with unknown endpoint")
        manager.syncAll { _ in pass.fulfill() }
        wait(for: [pass], timeout: 10)

        XCTAssertTrue(usageStore.linkBuckets(since: since).isEmpty)
        XCTAssertTrue(usageStore.linkEvents(since: since).isEmpty)
    }
}
