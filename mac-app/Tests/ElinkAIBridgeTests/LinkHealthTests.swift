import XCTest
@testable import ElinkAIBridge

/// 出口 NAT 事件的存储层。
///
/// 这里曾经还测过“同步往返”——把集群同步的 HTTP 耗时当作链路延迟。那条路径已经
/// 删掉：它测的是另一批机器（只有装了本应用并配对过的几台）走的另一条路径（Bonjour
/// 发现的局域网地址，不是 overlay），拿它回答“nebula 网络通不通”方向就是错的。
/// 网格可达性和延迟现在归 elink-tui 的 mesh 模块，判据是对 overlay 地址的 ICMP。
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

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testEventsReadBackNewestFirstAndRespectLimit() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordLinkEvent(LinkEvent(
            occurredAt: base, nodeID: "n1", kind: .wanRebind,
            detail: "123.158.49.251 → 124.90.54.149"
        ))
        store.recordLinkEvent(LinkEvent(
            occurredAt: base.addingTimeInterval(60), nodeID: "n1",
            kind: .portRewritten, detail: nil
        ))

        let events = store.linkEvents(since: base.addingTimeInterval(-600))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .portRewritten)
        XCTAssertNil(events[0].detail)
        XCTAssertEqual(events[1].kind, .wanRebind)
        XCTAssertEqual(events[1].detail, "123.158.49.251 → 124.90.54.149")

        XCTAssertEqual(store.linkEvents(since: base.addingTimeInterval(-600), limit: 1).count, 1)
        XCTAssertTrue(store.linkEvents(since: base.addingTimeInterval(600)).isEmpty)
    }

    /// 旧库升级后表为空，读取路径不能崩
    func testFreshDatabaseReturnsEmptyHistory() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(store.linkEvents(since: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    /// 每种事件都要能原样存取，否则某一类跃迁会在写入后静默消失
    func testEveryEventKindRoundTrips() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let kinds: [LinkEventKind] = [.wanRebind, .portPreserved, .portRewritten, .stunUnavailable]
        for (index, kind) in kinds.enumerated() {
            store.recordLinkEvent(LinkEvent(
                occurredAt: base.addingTimeInterval(Double(index)),
                nodeID: "n1", kind: kind, detail: nil
            ))
        }
        let events = store.linkEvents(since: base.addingTimeInterval(-1))
        XCTAssertEqual(events.count, kinds.count)
        XCTAssertEqual(Set(events.map(\.kind)), Set(kinds))
    }

    /// 出口 NAT 是本机自身的属性，只该出现在本机那一行；对端行不能有它。
    func testEgressNatRowIsLocalOnly() {
        let node = ClusterNodeRecord(nodeID: "peer", name: "Chyi's iMac",
                                     endpoint: "http://192.168.100.12:8765",
                                     lastSeenAt: base, lastSyncAt: base)
        let observation = StunObservation(localPort: 58682,
                                          externalAddress: "223.95.78.14",
                                          externalPort: 58682)

        let localRows = UsagePanelView.clusterNodeDetails(
            node, isLocal: true, localEndpoint: "http://host:8765",
            peers: [], stun: observation, stunUnavailable: false
        )
        XCTAssertTrue(localRows.contains { $0.label == tr("出口 NAT", "Egress NAT") })

        let peerRows = UsagePanelView.clusterNodeDetails(
            node, isLocal: false, localEndpoint: nil, peers: []
        )
        XCTAssertFalse(peerRows.contains { $0.label == tr("出口 NAT", "Egress NAT") })
    }

    /// 集群摘要只负责用量同步，不再声称任何链路质量。
    func testStatusJSONNoLongerCarriesLinkQuality() throws {
        var snapshot = BridgeSnapshot()
        snapshot.cluster = ClusterSummary(enabled: true, nodeCount: 4, onlineCount: 2,
                                          lastSyncedAt: base)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any]
        )
        let cluster = try XCTUnwrap(object["cluster"] as? [String: Any])
        XCTAssertEqual(cluster["node_count"] as? Int, 4)
        XCTAssertNil(cluster["link"], "链路质量不再属于集群摘要")
    }
}
