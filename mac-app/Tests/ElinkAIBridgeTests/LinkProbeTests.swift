import XCTest
@testable import ElinkAIBridge

final class LinkProbeTests: XCTestCase {
    // 断言依赖中文文案；语言默认跟随系统，这里固定为中文保证在英文系统的 CI 上稳定
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    private let transactionID = Data((0..<12).map { UInt8($0 + 1) })

    /// 223.95.78.14:4252 取自排障笔记里 DSM 换端口后的实际出口。
    /// 字节按 RFC 5389 手工异或后硬编码，避免测试把实现的异或逻辑抄一遍。
    private func realWorldResponse(transactionID: Data) -> Data {
        var data = Data([0x01, 0x01, 0x00, 0x0C])       // Binding Success, length 12
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        data.append(transactionID)
        data.append(contentsOf: [0x00, 0x20, 0x00, 0x08]) // XOR-MAPPED-ADDRESS, 8 bytes
        data.append(contentsOf: [0x00, 0x01, 0x31, 0x8E]) // IPv4, port 4252 ^ 0x2112
        data.append(contentsOf: [0xFE, 0x4D, 0xEA, 0x4C]) // 223.95.78.14 ^ magic cookie
        return data
    }

    func testRequestIsAWellFormedBindingRequest() {
        let request = StunProbe.request(transactionID: transactionID)
        XCTAssertEqual(request.count, 20)
        XCTAssertEqual(Array(request[0..<4]), [0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(Array(request[4..<8]), [0x21, 0x12, 0xA4, 0x42])
        XCTAssertEqual(Data(request[8..<20]), transactionID)
    }

    func testParsesXorMappedAddress() {
        let parsed = StunProbe.parseBinding(realWorldResponse(transactionID: transactionID),
                                            transactionID: transactionID)
        XCTAssertEqual(parsed?.0, "223.95.78.14")
        XCTAssertEqual(parsed?.1, 4252)
    }

    /// 串到同一个 socket 的其他 UDP 包不能被当成回复
    func testRejectsMismatchedTransactionIDAndNonSuccessMessages() {
        let other = Data((0..<12).map { UInt8($0 + 99) })
        XCTAssertNil(StunProbe.parseBinding(realWorldResponse(transactionID: other),
                                            transactionID: transactionID))

        var errorReply = realWorldResponse(transactionID: transactionID)
        errorReply[0] = 0x01
        errorReply[1] = 0x11 // Binding Error Response
        XCTAssertNil(StunProbe.parseBinding(errorReply, transactionID: transactionID))

        var wrongCookie = realWorldResponse(transactionID: transactionID)
        wrongCookie[4] = 0x00
        XCTAssertNil(StunProbe.parseBinding(wrongCookie, transactionID: transactionID))

        XCTAssertNil(StunProbe.parseBinding(Data([0x01, 0x01]), transactionID: transactionID))
    }

    /// 真实服务器会先放 SOFTWARE 之类的属性，解析必须跳过它们并处理 4 字节对齐填充
    func testSkipsPrecedingAttributesWithPadding() {
        var data = Data([0x01, 0x01, 0x00, 0x18])
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        data.append(transactionID)
        // SOFTWARE (0x8022), 5 字节值 + 3 字节填充
        data.append(contentsOf: [0x80, 0x22, 0x00, 0x05])
        data.append(contentsOf: [0x65, 0x6C, 0x69, 0x6E, 0x6B, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x00, 0x20, 0x00, 0x08])
        data.append(contentsOf: [0x00, 0x01, 0x31, 0x8E])
        data.append(contentsOf: [0xFE, 0x4D, 0xEA, 0x4C])

        let parsed = StunProbe.parseBinding(data, transactionID: transactionID)
        XCTAssertEqual(parsed?.0, "223.95.78.14")
        XCTAssertEqual(parsed?.1, 4252)
    }

    /// 声明长度超出实际字节数时必须放弃，而不是越界读取
    func testTruncatedAttributeIsRejected() {
        var data = Data([0x01, 0x01, 0x00, 0x0C])
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        data.append(transactionID)
        data.append(contentsOf: [0x00, 0x20, 0x00, 0x08])
        data.append(contentsOf: [0x00, 0x01, 0x31, 0x8E]) // 值只有 4 字节
        XCTAssertNil(StunProbe.parseBinding(data, transactionID: transactionID))
    }

    // MARK: - 事件判定

    private func store(_ name: String = UUID().uuidString) -> (UsageStore, String) {
        let path = NSTemporaryDirectory() + "elink-probe-\(name).db"
        try? FileManager.default.removeItem(atPath: path)
        return (UsageStore(path: path), path)
    }

    private func monitor(_ store: UsageStore,
                         servers: [String] = ["a"],
                         probe: @escaping (String) -> StunObservation?) -> LinkMonitor {
        LinkMonitor(store: store, nodeID: { "local-node" }, servers: servers, probe: probe)
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstObservationEstablishesBaselineWithoutEvents() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sample = StunObservation(localPort: 4252, externalAddress: "223.95.78.14",
                                     externalPort: 4252)
        let subject = monitor(store) { _ in sample }

        subject.runOnce(now: epoch)

        XCTAssertEqual(subject.observation, sample)
        XCTAssertFalse(subject.unavailable)
        XCTAssertTrue(store.linkEvents(since: epoch.addingTimeInterval(-60)).isEmpty)
        XCTAssertEqual(store.lastExternalEndpoint(), "223.95.78.14:4252")
    }

    /// 保端口 NAT 下每次探测都会用一个新的本地端口，外部端口自然跟着变。
    /// 只有外部 IP 变了才是重拨，否则每分钟都会误报一次。
    func testChangedPortAloneIsNotAWanRebind() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var port: UInt16 = 58682
        let subject = monitor(store) { _ in
            StunObservation(localPort: port, externalAddress: "223.95.78.14", externalPort: port)
        }

        subject.runOnce(now: epoch)
        port = 61571
        subject.runOnce(now: epoch.addingTimeInterval(60))

        XCTAssertTrue(store.linkEvents(since: epoch.addingTimeInterval(-60)).isEmpty)
        XCTAssertEqual(store.lastExternalEndpoint(), "223.95.78.14:61571")
    }

    func testExternalAddressChangeRecordsWanRebind() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var address = "123.158.49.251"
        let subject = monitor(store) { _ in
            StunObservation(localPort: 4252, externalAddress: address, externalPort: 4252)
        }

        subject.runOnce(now: epoch)
        address = "124.90.54.149"
        subject.runOnce(now: epoch.addingTimeInterval(60))

        let events = store.linkEvents(since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .wanRebind)
        XCTAssertEqual(events[0].detail, "123.158.49.251 → 124.90.54.149")
    }

    /// 上一次观测存在库里，因此重启前后的那次重拨也不会漏记
    func testWanRebindIsDetectedAcrossRestarts() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        monitor(store) { _ in
            StunObservation(localPort: 4252, externalAddress: "123.158.49.251", externalPort: 4252)
        }.runOnce(now: epoch)

        // 新实例代表进程重启：内存状态清空，只有 usage.db 里的端点留了下来
        monitor(store) { _ in
            StunObservation(localPort: 4252, externalAddress: "223.95.78.14", externalPort: 4252)
        }.runOnce(now: epoch.addingTimeInterval(3600))

        let events = store.linkEvents(since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .wanRebind)
    }

    func testPortPreservationTransitionIsRecorded() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var external: UInt16 = 65080
        let subject = monitor(store) { _ in
            StunObservation(localPort: 65080, externalAddress: "223.95.78.14",
                            externalPort: external)
        }

        subject.runOnce(now: epoch)              // 保端口，建立基线
        external = 65264
        subject.runOnce(now: epoch.addingTimeInterval(60)) // 变成被改写

        let events = store.linkEvents(since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .portRewritten)
        XCTAssertEqual(events[0].detail, "65080 → 223.95.78.14:65264")
    }

    /// 单台服务器不可用不能让判据失效，这是配多台的唯一理由
    func testFallsBackToNextServer() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sample = StunObservation(localPort: 4252, externalAddress: "223.95.78.14",
                                     externalPort: 4252)
        let subject = monitor(store, servers: ["dead", "alive"]) { host in
            host == "alive" ? sample : nil
        }

        subject.runOnce(now: epoch)

        XCTAssertEqual(subject.observation, sample)
        XCTAssertFalse(subject.unavailable)
    }

    /// 全部失败必须显式降级并记一次，但持续故障不能反复刷事件
    func testTotalFailureDegradesOnceAndRecovers() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var reachable = false
        let sample = StunObservation(localPort: 4252, externalAddress: "223.95.78.14",
                                     externalPort: 4252)
        let subject = monitor(store, servers: ["a", "b"]) { _ in reachable ? sample : nil }

        subject.runOnce(now: epoch)
        subject.runOnce(now: epoch.addingTimeInterval(60))

        XCTAssertTrue(subject.unavailable)
        XCTAssertNil(subject.observation)
        let events = store.linkEvents(since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(events.count, 1, "持续不可用只应记一次")
        XCTAssertEqual(events[0].kind, .stunUnavailable)
        XCTAssertEqual(events[0].detail, "a, b")

        reachable = true
        subject.runOnce(now: epoch.addingTimeInterval(120))
        XCTAssertFalse(subject.unavailable)
        XCTAssertEqual(subject.observation, sample)
    }

    /// 两种 NAT 结果都是事实陈述，不能有一个被写成“正常”：
    /// 保端口才是端口争抢的前提条件，被改写反而不参与争抢。
    func testNatDetailTextStatesFactsWithoutVerdict() {
        let preserving = StunObservation(localPort: 58682, externalAddress: "223.95.78.14",
                                         externalPort: 58682)
        XCTAssertEqual(UsagePanelView.clusterNatDetail(preserving, unavailable: false),
                       "223.95.78.14:58682 · 保端口，在争抢池内")

        let rewriting = StunObservation(localPort: 65080, externalAddress: "223.95.78.14",
                                        externalPort: 65264)
        XCTAssertEqual(UsagePanelView.clusterNatDetail(rewriting, unavailable: false),
                       "223.95.78.14:65264 · 端口被改写，不参与争抢")

        // 判据失效必须说出来，不能显示成空白让人误以为一切正常
        XCTAssertEqual(UsagePanelView.clusterNatDetail(nil, unavailable: true),
                       "STUN 不可达，端口判据暂时失效")
        XCTAssertNil(UsagePanelView.clusterNatDetail(nil, unavailable: false))
    }

    func testPortPreservationJudgement() {
        let preserving = StunObservation(localPort: 58682, externalAddress: "223.95.78.14",
                                         externalPort: 58682)
        XCTAssertTrue(preserving.portPreserved)
        XCTAssertEqual(preserving.externalEndpoint, "223.95.78.14:58682")

        // 排障笔记里 M4 的实际观测：经 TUN 代理，源端口被重写
        let rewriting = StunObservation(localPort: 65080, externalAddress: "223.95.78.14",
                                        externalPort: 65264)
        XCTAssertFalse(rewriting.portPreserved)
    }
}
