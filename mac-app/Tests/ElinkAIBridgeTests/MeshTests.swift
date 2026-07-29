import XCTest
@testable import ElinkAIBridge

/// nebula overlay 视图：设备清单、可达性判定与呈现。
final class MeshTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    // MARK: - ICMP

    /// 正确的 echo request 就地校验和为零，这正是接收方会做的事
    func testEchoRequestIsWellFormedAndSelfVerifying() {
        let packet = [UInt8](IcmpProbe.echoRequest(sequence: 7))
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(UInt16(packet[6]) << 8 | UInt16(packet[7]), 7)
        XCTAssertEqual(Array(packet[8...]), Array("elink-ai".utf8))
        XCTAssertEqual(IcmpProbe.checksum(packet), 0, "校验和必须就地验证通过")
    }

    /// RFC 1071 的已知答案，避免校验和只是自洽而不正确
    func testChecksumMatchesTheRFCExample() {
        XCTAssertEqual(IcmpProbe.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]), 0x220d)
    }

    func testChecksumHandlesOddLength() {
        XCTAssertEqual(IcmpProbe.checksum([0x12, 0x34, 0x56]),
                       IcmpProbe.checksum([0x12, 0x34, 0x56, 0x00]))
    }

    private func reply(sequence: UInt16) -> Data {
        var packet = [UInt8](IcmpProbe.echoRequest(sequence: sequence))
        packet[0] = 0
        return Data(packet)
    }

    func testAcceptsABareReplyAndRejectsAForeignOne() {
        XCTAssertTrue(IcmpProbe.matchesReply(reply(sequence: 3), sequence: 3))
        XCTAssertFalse(IcmpProbe.matchesReply(reply(sequence: 3), sequence: 4), "序号必须匹配")

        var untagged = [UInt8](reply(sequence: 3))
        untagged[8] = UInt8(ascii: "x")
        XCTAssertFalse(IcmpProbe.matchesReply(Data(untagged), sequence: 3), "载荷令牌必须匹配")

        XCTAssertFalse(IcmpProbe.matchesReply(IcmpProbe.echoRequest(sequence: 3), sequence: 3),
                       "request 不是 reply")
        XCTAssertFalse(IcmpProbe.matchesReply(Data(), sequence: 3))
    }

    /// macOS 可能连 IP 头一起递过来；猜错会把每台主机都报成不可达，所以要能识别
    func testAcceptsAReplyBehindAnIPHeader() {
        var framed: [UInt8] = [0x45, 0x00, 0x00, 0x24]
        framed.append(contentsOf: [UInt8](repeating: 0, count: 16))
        framed.append(contentsOf: [UInt8](reply(sequence: 9)))
        XCTAssertTrue(IcmpProbe.matchesReply(Data(framed), sequence: 9))
        XCTAssertFalse(IcmpProbe.matchesReply(Data(framed), sequence: 8))
    }

    func testRejectsATruncatedIPHeader() {
        XCTAssertFalse(IcmpProbe.matchesReply(Data([0x45, 0x00, 0x00]), sequence: 1))
        var short: [UInt8] = [0x40]
        short.append(contentsOf: [UInt8](reply(sequence: 1)))
        XCTAssertFalse(IcmpProbe.matchesReply(Data(short), sequence: 1), "头长度低于最小值")
    }

    // MARK: - 判定

    /// 问两个观测点的全部意义：WSL 和 iMac 从本机看一模一样，只有 lighthouse 能分开
    func testClassificationSeparatesABrokenTunnelFromADeadHost() {
        XCTAssertEqual(MeshMonitor.classify(local: 1390, lighthouseReachable: true), .online)
        XCTAssertEqual(MeshMonitor.classify(local: nil, lighthouseReachable: true), .tunnelDown)
        XCTAssertEqual(MeshMonitor.classify(local: nil, lighthouseReachable: false), .offline)
        XCTAssertEqual(MeshMonitor.classify(local: nil, lighthouseReachable: nil), .unreachable)
    }

    /// 本机能到达就算在线：用户问的是本机能和谁通话
    func testALocalSuccessOutranksTheLighthouse() {
        XCTAssertEqual(MeshMonitor.classify(local: 220, lighthouseReachable: false), .online)
        XCTAssertEqual(MeshMonitor.classify(local: 220, lighthouseReachable: nil), .online)
    }

    // MARK: - 名册

    /// 与已部署的 lighthouse 实际返回的形状一致
    func testRosterParsesEveryProbeState() {
        let body = """
        {"schema_version":2,"generated_at":1785314411,"default_port":4242,
         "hosts":[
           {"name":"Mini-M4","overlay":"192.168.100.24","last_activity_at":1785233489,
            "probed_at":1785314400,"rtt_us":224918},
           {"name":"iMac","overlay":"192.168.100.12","last_activity_at":1785288941,
            "probed_at":1785314400,"rtt_us":null},
           {"name":"WSL","overlay":"192.168.100.26","last_activity_at":1785319550,
            "probed_at":null,"rtt_us":null}],
         "wan":[]}
        """
        let roster = MeshMonitor.parseRoster(Data(body.utf8))
        XCTAssertEqual(roster.count, 3)
        XCTAssertEqual(roster[0].overlay, "192.168.100.24")
        XCTAssertEqual(roster[0].lighthouseReachable, true)
        XCTAssertEqual(roster[0].lighthouseRttUs, 224918)
        XCTAssertEqual(roster[1].lighthouseReachable, false)
        XCTAssertNil(roster[2].lighthouseReachable, "从未探测过不等于不可达")
    }

    /// lighthouse 挂了、正在升级或返回了别的东西，都不该让网格视图凭空捏造节点
    func testRosterSurvivesJunkWithoutInventingHosts() {
        XCTAssertTrue(MeshMonitor.parseRoster(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(MeshMonitor.parseRoster(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(MeshMonitor.parseRoster(Data(#"{"hosts":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(
            MeshMonitor.parseRoster(Data(#"{"hosts":[{"name":"X","overlay":"nope"}]}"#.utf8)).isEmpty,
            "没有可用地址的节点无法探测"
        )
    }

    /// 面板里手输地址通常不带 scheme，补全比报错友好
    func testLighthouseURLAcceptsABareHostPort() {
        XCTAssertEqual(MeshMonitor.lighthouseURL(from: "192.168.100.200:8767")?.absoluteString,
                       "http://192.168.100.200:8767")
        XCTAssertEqual(MeshMonitor.lighthouseURL(from: " http://a.b:1 ")?.absoluteString,
                       "http://a.b:1")
        XCTAssertNil(MeshMonitor.lighthouseURL(from: ""))
        XCTAssertNil(MeshMonitor.lighthouseURL(from: "   "))
    }

    // MARK: - 存储

    private func store() -> (UsageStore, String) {
        let path = NSTemporaryDirectory() + "elink-mesh-\(UUID().uuidString).db"
        try? FileManager.default.removeItem(atPath: path)
        return (UsageStore(path: path), path)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testSamplesAggregateIntoAlignedBuckets() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordMeshSample(hostName: "Mini-M4", at: base, rttUs: 1110)
        store.recordMeshSample(hostName: "Mini-M4", at: base.addingTimeInterval(50), rttUs: 1390)

        let aggregate = try? XCTUnwrap(store.meshAggregates(since: base.addingTimeInterval(-600))["Mini-M4"])
        XCTAssertEqual(aggregate?.samples, 2)
        XCTAssertEqual(aggregate?.okSamples, 2)
        XCTAssertEqual(aggregate?.rttMinUs, 1110)
        XCTAssertEqual(aggregate?.rttMaxUs, 1390)
    }

    /// 窗口内一次都没通，就不该留下任何延迟数字，否则图上会画出一条不存在的 0ms 线
    func testAFullyFailedWindowKeepsNoLatency() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordMeshSample(hostName: "iMac", at: base, rttUs: nil)
        store.recordMeshSample(hostName: "iMac", at: base.addingTimeInterval(30), rttUs: nil)

        let aggregate = store.meshAggregates(since: base.addingTimeInterval(-600))["iMac"]
        XCTAssertEqual(aggregate?.samples, 2)
        XCTAssertEqual(aggregate?.okSamples, 0)
        XCTAssertNil(aggregate?.rttMinUs)
        XCTAssertNil(aggregate?.rttMaxUs)
    }

    /// 两种顺序都要测：写反的 COALESCE 只会破坏其中一种
    func testFailedProbesDoNotMoveTheLatencyBounds() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordMeshSample(hostName: "fail-first", at: base, rttUs: nil)
        store.recordMeshSample(hostName: "fail-first", at: base.addingTimeInterval(15), rttUs: 2050)
        store.recordMeshSample(hostName: "ok-first", at: base, rttUs: 2050)
        store.recordMeshSample(hostName: "ok-first", at: base.addingTimeInterval(15), rttUs: nil)

        let all = store.meshAggregates(since: base.addingTimeInterval(-600))
        for name in ["fail-first", "ok-first"] {
            XCTAssertEqual(all[name]?.samples, 2, name)
            XCTAssertEqual(all[name]?.okSamples, 1, name)
            XCTAssertEqual(all[name]?.rttMinUs, 2050, name)
            XCTAssertEqual(all[name]?.rttMaxUs, 2050, name)
        }
    }

    // MARK: - 呈现

    /// 局域网 overlay 往返普遍不到一毫秒，不能全都塌成同一个 "0ms"
    func testLatencyKeepsSubMillisecondDetailButNotNoise() {
        XCTAssertEqual(UsagePanelView.meshLatency(360), "0.36ms")
        XCTAssertEqual(UsagePanelView.meshLatency(1390), "1.39ms")
        XCTAssertEqual(UsagePanelView.meshLatency(61450), "61ms")
        XCTAssertEqual(UsagePanelView.meshLatency(221180), "221ms")
    }

    /// 判「隧道未通」是在断言别人的机器活着，所以文案要带上依据
    func testStateTextNamesItsEvidence() {
        func host(_ state: MeshState, lighthouse: Int?) -> MeshHostView {
            MeshHostView(name: "WSL", overlay: "192.168.100.26", state: state,
                         lighthouseRttUs: lighthouse)
        }
        XCTAssertEqual(UsagePanelView.meshStateText(host(.online, lighthouse: nil)), "在线")
        XCTAssertEqual(UsagePanelView.meshStateText(host(.tunnelDown, lighthouse: 211517)),
                       "隧道未通（lighthouse 212ms）")
        XCTAssertEqual(UsagePanelView.meshStateText(host(.tunnelDown, lighthouse: nil)),
                       "隧道未通", "没有 lighthouse 的数字就没有依据可引")
        XCTAssertEqual(UsagePanelView.meshStateText(host(.offline, lighthouse: nil)), "离线")
        XCTAssertEqual(UsagePanelView.meshStateText(host(.unreachable, lighthouse: nil)),
                       "不可达，原因未知")
    }

    // MARK: - 数据年龄与历史

    /// 陈旧必须可见：不写年龄，30 秒前的数字就会冒充实时数字
    func testSubtitleMakesStalenessVisible() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            UsagePanelView.meshSubtitle(total: 10, reachable: 8, updatedAt: nil, now: now),
            "10 台设备 · 8 台本机可达 · 尚未探测"
        )
        XCTAssertEqual(
            UsagePanelView.meshSubtitle(total: 10, reachable: 8,
                                        updatedAt: now.addingTimeInterval(-12), now: now),
            "10 台设备 · 8 台本机可达 · 12 秒前"
        )
        XCTAssertEqual(
            UsagePanelView.meshSubtitle(total: 10, reachable: 8,
                                        updatedAt: now.addingTimeInterval(-185), now: now),
            "10 台设备 · 8 台本机可达 · 3 分钟前"
        )
        // 时钟回拨不该显示负数年龄
        XCTAssertEqual(
            UsagePanelView.meshSubtitle(total: 1, reachable: 1,
                                        updatedAt: now.addingTimeInterval(30), now: now),
            "1 台设备 · 1 台本机可达 · 0 秒前"
        )
    }

    private func point(_ offset: TimeInterval, min: Int?, max: Int?,
                       samples: Int = 10, ok: Int = 10) -> MeshBucketPoint {
        MeshBucketPoint(bucketAt: base.addingTimeInterval(offset),
                        samples: samples, okSamples: ok,
                        rttMinUs: min, rttMaxUs: max,
                        rttAvgUs: ok > 0 ? min : nil)
    }

    /// 「平均 1.4ms」配上「三分之一探测没回来」是完全不同的一件事，摘要必须说出丢样
    func testHistorySummaryAlwaysReportsLoss() {
        let points = [point(0, min: 1_100, max: 1_700),
                      point(300, min: 900, max: 42_000, samples: 10, ok: 7)]
        XCTAssertEqual(
            UsagePanelView.meshHistorySummary(points: points, hovered: nil),
            "0.90ms–42ms · 20 次探测 · 丢 3"
        )

        let clean = [point(0, min: 1_100, max: 1_700)]
        XCTAssertEqual(
            UsagePanelView.meshHistorySummary(points: clean, hovered: nil),
            "1.10ms–1.70ms · 10 次探测"
        )
    }

    /// 一个桶整段不通时，摘要不能借用别处的延迟数字来填空
    func testHistorySummaryHandlesATotallyLostWindow() {
        let dead = [point(0, min: nil, max: nil, samples: 10, ok: 0)]
        XCTAssertEqual(
            UsagePanelView.meshHistorySummary(points: dead, hovered: nil),
            "10 次探测全部丢失"
        )
        XCTAssertEqual(
            UsagePanelView.meshHistorySummary(points: [], hovered: nil),
            "暂无历史数据"
        )
    }

    /// 悬停时说明那一个桶而不是整段窗口
    func testHoveredBucketDescribesItself() {
        let hovered = point(0, min: 1_100, max: 1_700, samples: 10, ok: 8)
        let text = UsagePanelView.meshHistorySummary(points: [hovered], hovered: hovered)
        XCTAssertTrue(text.contains("1.10ms–1.70ms"), text)
        XCTAssertTrue(text.contains("丢 2/10"), text)

        let dead = point(0, min: nil, max: nil, samples: 10, ok: 0)
        XCTAssertTrue(
            UsagePanelView.meshHistorySummary(points: [dead], hovered: dead)
                .contains("全部丢失（10 次探测）")
        )
    }

    /// 一次都没通的桶必须以 fullyLost 标出来，图上才画得成断口而不是 0ms 的柱子
    func testHistoryReadsBackInOrderAndMarksDeadBuckets() {
        let (store, path) = store()
        defer { try? FileManager.default.removeItem(atPath: path) }

        store.recordMeshSample(hostName: "Mini-M4", at: base, rttUs: 1_466)
        store.recordMeshSample(hostName: "Mini-M4", at: base.addingTimeInterval(400), rttUs: nil)
        store.recordMeshSample(hostName: "iMac", at: base, rttUs: nil)

        let history = store.meshHistory(hostName: "Mini-M4",
                                        since: base.addingTimeInterval(-600))
        XCTAssertEqual(history.count, 2, "只返回这一台的桶")
        XCTAssertLessThan(history[0].bucketAt, history[1].bucketAt, "按时间正序")
        XCTAssertEqual(history[0].rttMinUs, 1_466)
        XCTAssertFalse(history[0].fullyLost)
        XCTAssertNil(history[1].rttMinUs, "没通的桶不能有延迟值")
        XCTAssertTrue(history[1].fullyLost)
    }

    // MARK: - 折线的断口

    /// 跨着一段断网把两端连起来，会画出一条那段时间根本不存在的延迟曲线。
    /// 这比画成 0ms 更隐蔽，所以断口必须把折线切开。
    func testLineBreaksAcrossADeadWindow() {
        let series = [point(0, min: 1_100, max: 1_700),
                      point(300, min: 1_200, max: 1_900),
                      point(600, min: nil, max: nil, samples: 10, ok: 0),
                      point(900, min: nil, max: nil, samples: 10, ok: 0),
                      point(1_200, min: 900, max: 1_400)]
        XCTAssertEqual(MeshLatencyChart.segments(series), [[0, 1], [4]],
                       "两段之间不能连线")
    }

    /// 首尾都是断口时不能留下空段，否则会画出零长度的路径
    func testSegmentsIgnoreLeadingAndTrailingGaps() {
        let series = [point(0, min: nil, max: nil, samples: 5, ok: 0),
                      point(300, min: 1_100, max: 1_700),
                      point(600, min: nil, max: nil, samples: 5, ok: 0)]
        XCTAssertEqual(MeshLatencyChart.segments(series), [[1]])
        XCTAssertTrue(MeshLatencyChart.segments([]).isEmpty)
        XCTAssertTrue(
            MeshLatencyChart.segments([point(0, min: nil, max: nil, samples: 5, ok: 0)]).isEmpty
        )
    }

    /// 全程可用时就是一整条线，不该被切碎
    func testAHealthyWindowIsOneSegment() {
        let series = (0..<5).map { point(Double($0) * 300, min: 1_000, max: 1_500) }
        XCTAssertEqual(MeshLatencyChart.segments(series), [[0, 1, 2, 3, 4]])
    }

    // MARK: - 纵轴与空图

    /// 零基线把 199–221ms 压进图的顶部一成，波动整个消失——这是实测截图里看到的问题。
    /// 纵轴必须贴着数据自己的范围。
    func testAxisTracksTheDataRangeNotZero() {
        let series = [point(0, min: 199_000, max: 210_000),
                      point(300, min: 205_000, max: 221_000)]
        let chart = MeshLatencyChart(points: series, theme: PanelTheme(.light))
        let (lower, upper) = chart.axisBounds
        XCTAssertGreaterThan(lower, 150_000, "下界不能退到零")
        XCTAssertLessThan(lower, 199_000, "下界要留出余量")
        XCTAssertGreaterThan(upper, 221_000, "上界要留出余量")
    }

    /// 一条水平线也要能画出来，不能因为 span 为零而除零或贴边
    func testAFlatSeriesStillGetsHeadroom() {
        let series = [point(0, min: 1_000, max: 1_000), point(300, min: 1_000, max: 1_000)]
        let (lower, upper) = MeshLatencyChart(points: series, theme: PanelTheme(.light)).axisBounds
        XCTAssertLessThan(lower, 1_000)
        XCTAssertGreaterThan(upper, 1_000)
    }

    /// 全程不通时没有曲线可画；留一个空图框会让人以为渲染坏了
    func testAnAllLostWindowHasNothingToPlot() {
        let dead = [point(0, min: nil, max: nil, samples: 10, ok: 0),
                    point(300, min: nil, max: nil, samples: 10, ok: 0)]
        XCTAssertFalse(MeshLatencyChart(points: dead, theme: PanelTheme(.light)).hasPlottableData)

        let alive = [point(0, min: 1_000, max: 1_200)]
        XCTAssertTrue(MeshLatencyChart(points: alive, theme: PanelTheme(.light)).hasPlottableData)
        XCTAssertFalse(MeshLatencyChart(points: [], theme: PanelTheme(.light)).hasPlottableData)
    }

    // MARK: - 打开面板时的补探

    /// 守卫的意义：反复开关面板不能把 sweep 排成队列。探测队列是串行的，一轮全网
    /// 约四秒，堆几轮就变成持续发包。
    func testRefreshSkipsWhenTheDataIsStillFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(MeshMonitor.isStale(now.addingTimeInterval(-3), maxAge: 10, now: now))
        XCTAssertFalse(MeshMonitor.isStale(now.addingTimeInterval(-9.9), maxAge: 10, now: now))
    }

    /// 满了阈值就该补，否则第一眼要等满 30 秒的常规节拍
    func testRefreshFiresOnceTheDataIsStale() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(MeshMonitor.isStale(now.addingTimeInterval(-10), maxAge: 10, now: now))
        XCTAssertTrue(MeshMonitor.isStale(now.addingTimeInterval(-25), maxAge: 10, now: now))
    }

    /// 从未探测过也算旧——那正是最需要补一轮的时候
    func testNeverProbedCountsAsStale() {
        XCTAssertTrue(MeshMonitor.isStale(nil, maxAge: 10))
        XCTAssertTrue(MeshMonitor.isStale(nil, maxAge: 3600))
    }
}
