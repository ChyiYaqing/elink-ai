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

    /// 覆盖住测试数据的横轴范围。
    private func axis(_ seconds: TimeInterval = 3_600) -> ClosedRange<Date> {
        base.addingTimeInterval(-300)...base.addingTimeInterval(seconds)
    }

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

    /// 图里三种标记必须两两分得开。可达性色带删掉之后，「多慢 / 丢了多少 / 全不通」
    /// 全靠这三个颜色区分，撞色就等于把一次中断说成一次抖动。
    func testTheChartMarksStayDistinct() {
        for dark in [false, true] {
            let theme = PanelTheme(dark ? .dark : .light)
            let marks = [theme.seriesColor.opacity(dark ? 0.38 : 0.28),
                         theme.statusWarning,
                         theme.statusCritical]
            XCTAssertEqual(Set(marks).count, marks.count, "dark=\(dark) 三种标记不能同色")
        }
    }

    /// 丢包标记的高度必须随比例走。
    ///
    /// 一律画满是这条路上踩过的坑：这张网上四台节点每五分钟都会丢一两个探测，
    /// 满高度的标记会让这四台看着和真的断掉一样严重，而那正是要区分的两件事。
    func testLossMarkGrowsWithTheLossFraction() {
        func height(samples: Int, ok: Int) -> CGFloat {
            MeshLatencyChart.lossMarkHeight(
                MeshBucketPoint(bucketAt: base, samples: samples, okSamples: ok,
                                rttMinUs: ok > 0 ? 9_000 : nil,
                                rttMaxUs: ok > 0 ? 18_000 : nil,
                                rttAvgUs: ok > 0 ? 12_000 : nil))
        }

        XCTAssertEqual(height(samples: 10, ok: 10), 0, "一个都没丢就不该有标记")
        XCTAssertEqual(height(samples: 0, ok: 0), 0, "根本没探测不是丢包")

        let occasional = height(samples: 16, ok: 15)
        let heavy = height(samples: 16, ok: 8)
        let outage = height(samples: 16, ok: 0)
        XCTAssertGreaterThan(occasional, 0, "丢一个探测也要看得见")
        XCTAssertLessThan(occasional, heavy, "零星丢包不能和大量丢包一样高")
        XCTAssertLessThan(heavy, outage, "全丢必须是最高的那一档")
    }

    // MARK: - 纵轴与空图

    /// 零基线把 199–221ms 压进图的顶部一成，波动整个消失——这是实测截图里看到的问题。
    /// 纵轴必须贴着数据自己的范围。
    func testAxisTracksTheDataRangeNotZero() {
        let series = [point(0, min: 199_000, max: 210_000),
                      point(300, min: 205_000, max: 221_000)]
        let chart = MeshLatencyChart(points: series, window: axis(), theme: PanelTheme(.light))
        let (lower, upper) = chart.axisBounds
        XCTAssertGreaterThan(lower, 150_000, "下界不能退到零")
        XCTAssertLessThan(lower, 199_000, "下界要留出余量")
        XCTAssertGreaterThan(upper, 221_000, "上界要留出余量")
    }

    /// 一次尖峰不能把日常波动压平。
    ///
    /// 实测截图：本机 → 3B 的窗口是 8.88ms–481ms，日常在 10–35ms，481ms 是单次探测的
    /// 尖峰。线性纵轴下这段日常波动只占图高的 5%，均值线成了一条贴着底边的平线，
    /// 而「波动」正是这张图要回答的问题。
    func testASingleSpikeDoesNotFlattenTheEverydayRange() {
        var series = [point(0, min: 8_880, max: 12_000),
                      point(300, min: 9_500, max: 35_000),
                      point(600, min: 10_000, max: 28_000)]
        series.append(point(900, min: 12_000, max: 481_000))  // 尖峰
        let chart = MeshLatencyChart(points: series, window: axis(), theme: PanelTheme(.light))

        let everyday = chart.plotRatio(35_000) - chart.plotRatio(10_000)
        XCTAssertGreaterThan(everyday, 0.2,
                             "10–35ms 这段日常波动至少要占图高的两成，否则读不出抖动")
        XCTAssertLessThan(chart.plotRatio(481_000), 1.0001, "尖峰仍然画在图内，没有被砍掉")
        XCTAssertGreaterThan(chart.plotRatio(481_000), everyday,
                             "尖峰仍然是这张图的最高点")
    }

    /// 窄范围的序列不能因为换了刻度就退化：Bandwagon2 的 199–221ms 仍要铺开
    func testANarrowRangeStillFillsTheChart() {
        let series = [point(0, min: 199_000, max: 210_000),
                      point(300, min: 205_000, max: 221_000)]
        let chart = MeshLatencyChart(points: series, window: axis(), theme: PanelTheme(.light))
        XCTAssertGreaterThan(chart.plotRatio(221_000) - chart.plotRatio(199_000), 0.7,
                             "整段数据要占满图高的大部分")
    }

    /// 一条水平线也要能画出来，不能因为 span 为零而除零或贴边
    func testAFlatSeriesStillGetsHeadroom() {
        let series = [point(0, min: 1_000, max: 1_000), point(300, min: 1_000, max: 1_000)]
        let (lower, upper) = MeshLatencyChart(points: series, window: axis(),
                                              theme: PanelTheme(.light)).axisBounds
        XCTAssertLessThan(lower, 1_000)
        XCTAssertGreaterThan(upper, 1_000)
    }

    /// 全程不通时没有曲线可画；留一个空图框会让人以为渲染坏了
    func testAnAllLostWindowHasNothingToPlot() {
        let dead = [point(0, min: nil, max: nil, samples: 10, ok: 0),
                    point(300, min: nil, max: nil, samples: 10, ok: 0)]
        XCTAssertFalse(MeshLatencyChart(points: dead, window: axis(),
                                       theme: PanelTheme(.light)).hasPlottableData)

        let alive = [point(0, min: 1_000, max: 1_200)]
        XCTAssertTrue(MeshLatencyChart(points: alive, window: axis(),
                                      theme: PanelTheme(.light)).hasPlottableData)
        XCTAssertFalse(MeshLatencyChart(points: [], window: axis(),
                                       theme: PanelTheme(.light)).hasPlottableData)
    }

    // MARK: - 时间轴

    /// 本机休眠时一个桶都不会写，那几个小时在库里是**不存在**而不是「全丢」。
    /// 早期版本按下标定位，于是缺口被整个挤掉，凌晨两点和早上八点被画成相邻两点
    /// 连成一条连续的线——夜里断没断，在那种轴上永远看不出来。
    func testAbsentBucketsBreakTheLineInsteadOfCollapsing() {
        let series = [point(0, min: 1_100, max: 1_700),
                      point(300, min: 1_200, max: 1_900),
                      // 中间六小时没有任何桶：本机睡着了
                      point(21_600, min: 900, max: 1_400),
                      point(21_900, min: 950, max: 1_500)]
        XCTAssertEqual(MeshLatencyChart.segments(series), [[0, 1], [2, 3]],
                       "隔着六小时空白的两段不能连成一条线")
    }

    /// 横坐标必须按时间取，否则空白时段在轴上不占宽度
    func testPositionsFollowTimeNotOrder() {
        let window = base...base.addingTimeInterval(3_600)
        XCTAssertEqual(MeshLatencyChart.position(base, in: window, width: 100), 0)
        XCTAssertEqual(MeshLatencyChart.position(base.addingTimeInterval(1_800),
                                                 in: window, width: 100), 50)
        XCTAssertEqual(MeshLatencyChart.position(base.addingTimeInterval(3_600),
                                                 in: window, width: 100), 100)
        // 窗口外的点被夹住而不是画到框外
        XCTAssertEqual(MeshLatencyChart.position(base.addingTimeInterval(-9_999),
                                                 in: window, width: 100), 0)
    }

    // MARK: - lighthouse 历史

    /// 本机视角测不到 lighthouse 到 DS925 那条隧道，昨晚断的恰恰是它。
    /// 这份文档是唯一的证据来源，解析必须完整保留丢失桶的「没有延迟值」。
    func testLighthouseHistoryKeepsTheOutageBucket() throws {
        let json = """
        {"schema_version":1,"generated_at":1700003600,"since":1700000000,
         "bucket_width_s":300,
         "fields":["bucket_at","samples","ok_samples","rtt_min_us","rtt_max_us","rtt_sum_us"],
         "hosts":[{"name":"DS925","buckets":[
           [1700000000,10,10,199000,221000,2100000],
           [1700000300,10,0,null,null,null],
           [1700000600,10,6,205000,240000,1300000]]}]}
        """
        let history = try XCTUnwrap(MeshMonitor.parseHistory(Data(json.utf8)))
        let points = try XCTUnwrap(history["DS925"])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].rttAvgUs, 210_000)
        XCTAssertTrue(points[1].fullyLost)
        XCTAssertNil(points[1].rttAvgUs, "全丢的桶不能有延迟值，否则画成 0ms")
        XCTAssertEqual(points[2].lostSamples, 4)
    }

    /// 老版本 lighthouse 对任何路径都回名册，两份文档都有 hosts 键。当成空历史会把
    /// 「lighthouse 太旧」显示成「这段时间一切正常」。
    func testARosterDocumentIsNotMistakenForHistory() {
        let roster = """
        {"schema_version":2,"generated_at":1700000000,"default_port":4242,
         "hosts":[{"name":"DS925","overlay":"192.168.100.125","last_activity_at":1,
                   "probed_at":1,"rtt_us":211000}],"wan":[]}
        """
        XCTAssertNil(MeshMonitor.parseHistory(Data(roster.utf8)),
                     "名册不是历史文档")
        XCTAssertNil(MeshMonitor.parseHistory(Data("not json".utf8)))
    }

    func testHistoryURLKeepsTheHostAndAsksForTheWindow() throws {
        let base = try XCTUnwrap(MeshMonitor.lighthouseURL(from: "192.168.100.200:8767"))
        let url = try XCTUnwrap(MeshMonitor.historyURL(base: base, window: 24 * 3_600))
        XCTAssertEqual(url.absoluteString, "http://192.168.100.200:8767/history?window=86400")
    }

    /// 三种缺席要分开说：没配地址、连不上、版本太旧。空图配一句「暂无数据」
    /// 会把它们说成同一件事，而处置方式完全不同。
    func testEachKindOfMissingHistorySaysWhich() {
        let notice = { MeshDetailView.lighthouseNotice($0, hasSeries: false) }
        XCTAssertNotEqual(notice(.notConfigured), notice(.unreachable))
        XCTAssertNotEqual(notice(.unreachable), notice(.unsupported))
        XCTAssertNotNil(notice(nil), "没有报错但也没有序列，仍要说明")
        XCTAssertNil(MeshDetailView.lighthouseNotice(nil, hasSeries: true))
    }

    /// 一天的窗口分五段，首尾刻度的时刻必然相同；七天更是五个都可能撞上。
    /// 只写时刻会在轴的两端印出同一个标签，所以满一天就要带日期。
    func testWideWindowsGetDatedAxisLabels() {
        let english = Locale(identifier: "en_US")
        let hours = MeshDetailView.axisLabels(
            window: base...base.addingTimeInterval(6 * 3_600), locale: english)
        let day = MeshDetailView.axisLabels(
            window: base...base.addingTimeInterval(24 * 3_600), locale: english)
        let week = MeshDetailView.axisLabels(
            window: base...base.addingTimeInterval(7 * 24 * 3_600), locale: english)
        XCTAssertEqual(Set(hours).count, 5, "刻度不能重复")
        XCTAssertEqual(Set(day).count, 5, "刻度不能重复")
        XCTAssertEqual(Set(week).count, 5, "刻度不能重复")
        XCTAssertGreaterThan(day[0].count, hours[0].count, "满一天的窗口要带上日期")
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

    /// 没配地址时不能显示成「lighthouse 不可达」：那句话会让人去查网络，而实际上
    /// 一次名册请求都还没发出去过。
    func testMissingLighthouseAddressIsNotReportedAsUnreachable() {
        let unconfigured = UsagePanelView.meshRosterNotice(configured: false, reachable: false)
        XCTAssertNotNil(unconfigured)
        XCTAssertFalse(unconfigured?.contains("不可达") ?? true,
                       "从没发出过请求，不能说连不上：\(unconfigured ?? "")")
        XCTAssertEqual(
            UsagePanelView.meshRosterNotice(configured: false, reachable: true),
            unconfigured,
            "没有地址时 reachable 那一位没有意义，说法不该跟着变"
        )
        XCTAssertNotEqual(UsagePanelView.meshRosterNotice(configured: true, reachable: false),
                          unconfigured)
        XCTAssertNil(UsagePanelView.meshRosterNotice(configured: true, reachable: true),
                     "一切正常时不该有横幅")
    }

    // MARK: - 不可信文档的取值域

    /// 名册和历史都来自一份明文 HTTP 文档。Swift 的整数越界是 trap 而不是回绕，所以
    /// 一个 Int.max 就能把 app 打崩——图表要算 `high - low`，报表要算
    /// `samples - okSamples`。取值域在解析处就要收干净。
    func testHostileHistoryDocumentCannotProduceTrappingValues() throws {
        let hostile = """
        {"bucket_width_s":300,"hosts":[{"name":"evil","buckets":[
          [1785000000,5,4,-9223372036854775808,9223372036854775807,1],
          [1785000300,9223372036854775807,-9223372036854775808,1,2,3],
          [1785000600,5,9,1,2,3],
          [1785000900,-1,-1,1,2,3],
          [1785001200,5,4,200000,240000,880000]
        ]}]}
        """
        let parsed = try XCTUnwrap(MeshMonitor.parseHistory(Data(hostile.utf8)))
        let points = try XCTUnwrap(parsed["evil"])
        XCTAssertEqual(points.count, 2, "计数不自洽的桶要丢掉，实际留下：\(points)")

        for point in points {
            XCTAssertGreaterThanOrEqual(point.samples, 0)
            XCTAssertLessThanOrEqual(point.okSamples, point.samples)
            XCTAssertGreaterThanOrEqual(point.lostSamples, 0)
            for rtt in [point.rttMinUs, point.rttMaxUs, point.rttAvgUs].compactMap({ $0 }) {
                XCTAssertGreaterThanOrEqual(rtt, 0)
                XCTAssertLessThanOrEqual(rtt, MeshMonitor.maxPlausibleRttUs)
            }
        }
        // 极端值被剔除后仍要能画：这里真正保护的是「不 trap」，不是「不显示」
        let chart = MeshLatencyChart(points: points, window: axis(), theme: PanelTheme(.light))
        let (lower, upper) = chart.axisBounds
        XCTAssertTrue(lower.isFinite && upper.isFinite, "纵轴范围必须是有限值")
        XCTAssertLessThan(lower, upper)
    }

    /// 名册每多一条就多一次串行 ICMP 探测和一次落库，长度不能由对端说了算。
    func testHostileRosterIsBoundedInCountAndNameLength() throws {
        let entries = (0..<(MeshMonitor.maxRosterHosts + 50)).map { index in
            "{\"name\":\"n\(index)\",\"overlay\":\"192.168.100.\(index % 250 + 1)\"}"
        }
        let long = String(repeating: "x", count: MeshMonitor.maxHostNameLength + 1)
        let document = "{\"hosts\":[{\"name\":\"\(long)\",\"overlay\":\"192.168.100.9\"},"
            + entries.joined(separator: ",") + "]}"
        let roster = MeshMonitor.parseRoster(Data(document.utf8))
        XCTAssertLessThanOrEqual(roster.count, MeshMonitor.maxRosterHosts)
        XCTAssertFalse(roster.contains { $0.name == long }, "超长名字要丢掉")

        // 荒谬的往返值当作没有读数：少画一段线，好过 trap
        let absurdDocument = "{\"hosts\":[{\"name\":\"a\",\"overlay\":\"192.168.100.5\","
            + "\"probed_at\":1,\"rtt_us\":9223372036854775807}]}"
        let absurd = MeshMonitor.parseRoster(Data(absurdDocument.utf8))
        XCTAssertEqual(absurd.count, 1)
        XCTAssertNil(absurd[0].lighthouseRttUs)
        XCTAssertEqual(absurd[0].lighthouseReachable, false, "没有可信的往返值就不算探通")
    }

    // MARK: - 中断判定与摘要

    /// 一桶里丢一两个包和一桶全丢是两件事。实测这张网上有四台节点每五分钟都会丢
    /// 一两个探测，把它算成中断，页面上就只剩告警。
    func testOnlyFullyLostBucketsCountAsAnOutage() {
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        let series = (0..<6).map { index in
            MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                            samples: 5, okSamples: index == 3 ? 4 : 5,
                            rttMinUs: 200_000, rttMaxUs: 240_000, rttAvgUs: 220_000)
        }
        XCTAssertTrue(MeshAnalysis.outages(in: series).isEmpty, "丢一个包不是中断")
    }

    /// 连续全丢并成一段，缺桶的地方断开——缺桶是「没在探」，算进中断等于替一段
    /// 本机睡着的时间作证。
    func testConsecutiveDownBucketsMergeButGapsSplit() {
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        func down(_ index: Int) -> MeshBucketPoint {
            MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                            samples: 5, okSamples: 0,
                            rttMinUs: nil, rttMaxUs: nil, rttAvgUs: nil)
        }
        func good(_ index: Int) -> MeshBucketPoint {
            MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                            samples: 5, okSamples: 5,
                            rttMinUs: 200_000, rttMaxUs: 240_000, rttAvgUs: 220_000)
        }

        let merged = MeshAnalysis.outages(in: [down(0), down(1), down(2), good(3)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.buckets, 3)
        XCTAssertEqual(merged.first?.start, start)
        XCTAssertEqual(merged.first?.end, start.addingTimeInterval(900))
        XCTAssertFalse(merged.first?.ongoing ?? true, "后面还有通的桶，已经恢复")

        // 第 2 桶完全没有记录（本机休眠），不能把 0 和 3 连成一段 20 分钟的中断
        let split = MeshAnalysis.outages(in: [down(0), down(1), down(3)])
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.map(\.buckets), [2, 1])
        XCTAssertTrue(split.last?.ongoing ?? false, "最后一个桶就是全丢的，还没恢复")
    }

    /// 没恢复和已恢复要分开说：前者是现在的事故。整窗口都断则连起点都不该说，
    /// 「18:10 起不通」会让人以为 18:10 之前是好的。
    func testOutageTextSeparatesOngoingFromRecovered() {
        let english = Locale(identifier: "en_US")
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        let window = start...start.addingTimeInterval(3600)
        func down(_ index: Int) -> MeshBucketPoint {
            MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                            samples: 5, okSamples: 0,
                            rttMinUs: nil, rttMaxUs: nil, rttAvgUs: nil)
        }
        func good(_ index: Int) -> MeshBucketPoint {
            MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                            samples: 5, okSamples: 5,
                            rttMinUs: 200_000, rttMaxUs: 240_000, rttAvgUs: 220_000)
        }

        // locale 只决定时钟格式；文案跟随 app 语言，这个测试类固定中文
        let recovered = MeshAnalysis.outageText(
            MeshAnalysis.outages(in: [down(0), down(1), good(2)]),
            window: window, locale: english)
        XCTAssertTrue(recovered?.contains("–") ?? false, "已恢复要给出闭区间：\(recovered ?? "")")
        XCTAssertTrue(recovered?.hasSuffix("不通") ?? false, "已恢复要给出闭区间：\(recovered ?? "")")

        let wholeWindow = MeshAnalysis.outageText(
            MeshAnalysis.outages(in: [down(0), down(1), down(2)]),
            window: window, locale: english)
        XCTAssertEqual(wholeWindow, "整个窗口都不通")

        let since = MeshAnalysis.outageText(
            MeshAnalysis.outages(in: [good(0), good(1), down(2), down(3)]),
            window: window, locale: english)
        XCTAssertEqual(since?.hasSuffix(" 起不通"), true, "窗口内才断的要给起点：\(since ?? "")")
        XCTAssertFalse(since?.contains("–") ?? true, "还没恢复就没有终点可写：\(since ?? "")")

        XCTAssertNil(MeshAnalysis.outageText([], window: window, locale: english))
    }

    /// 现在不通 > 断过又好了 > 只是丢包 > 干净，同级按名字。出事的排在最后一个，
    /// 等于让人滚过九个健康的区块才看到问题。
    func testWorstHostsSortFirst() {
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        func series(ok: Int) -> [MeshBucketPoint] {
            (0..<3).map { index in
                MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                                samples: 5, okSamples: ok,
                                rttMinUs: ok > 0 ? 200_000 : nil,
                                rttMaxUs: ok > 0 ? 240_000 : nil,
                                rttAvgUs: ok > 0 ? 220_000 : nil)
            }
        }
        let reports = [
            MeshAnalysis.report(name: "clean", state: .online, local: series(ok: 5),
                                lighthouse: series(ok: 5)),
            MeshAnalysis.report(name: "iMac", state: .offline, local: series(ok: 0),
                                lighthouse: series(ok: 0)),
            MeshAnalysis.report(name: "AAPC", state: .online, local: series(ok: 5),
                                lighthouse: series(ok: 4)),
            MeshAnalysis.report(name: "WSL", state: .online, local: series(ok: 5),
                                lighthouse: [series(ok: 0)[0], series(ok: 5)[1], series(ok: 5)[2]]),
        ]
        XCTAssertEqual(MeshAnalysis.sorted(reports).map(\.name),
                       ["iMac", "WSL", "AAPC", "clean"])
        XCTAssertEqual(reports.map(\.fault), [.clean, .down, .loss, .recovered])

        // 同级再分：没恢复的排前面，其次断得久的。只按名字排会让整窗口不通的 iMac
        // 落到断过 5 分钟的 WSL 后面
        let ongoing = MeshAnalysis.report(name: "iMac", state: .online, local: [],
                                          lighthouse: series(ok: 0))
        let brief = MeshAnalysis.report(
            name: "AAPC", state: .online, local: [],
            lighthouse: [series(ok: 0)[0], series(ok: 5)[1], series(ok: 5)[2]])
        XCTAssertEqual(ongoing.fault, brief.fault, "两台都是「断过」")
        XCTAssertEqual(MeshAnalysis.sorted([brief, ongoing]).map(\.name), ["iMac", "AAPC"])
    }

    /// 顶部那一句要在不滚动、不悬停的情况下把「什么时候有问题」答完。
    func testHeadlineNamesTheWorstHostsAndWhen() {
        let english = Locale(identifier: "en_US")
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        let window = start...start.addingTimeInterval(3600)
        func series(ok: Int) -> [MeshBucketPoint] {
            (0..<3).map { index in
                MeshBucketPoint(bucketAt: start.addingTimeInterval(Double(index) * 300),
                                samples: 5, okSamples: ok,
                                rttMinUs: ok > 0 ? 200_000 : nil,
                                rttMaxUs: ok > 0 ? 240_000 : nil,
                                rttAvgUs: ok > 0 ? 220_000 : nil)
            }
        }
        let clean = MeshAnalysis.report(name: "DS925", state: .online, local: series(ok: 5),
                                       lighthouse: series(ok: 5))
        let lossy = MeshAnalysis.report(name: "AAPC", state: .online, local: series(ok: 5),
                                       lighthouse: series(ok: 4))
        let down = MeshAnalysis.report(name: "iMac", state: .offline, local: series(ok: 0),
                                      lighthouse: series(ok: 0))

        XCTAssertEqual(MeshAnalysis.headline([clean], window: window, locale: english),
                       "窗口内没有中断")
        XCTAssertEqual(MeshAnalysis.headline([clean, lossy], window: window, locale: english),
                       "窗口内没有中断，只有零星丢包")
        let broken = MeshAnalysis.headline([clean, lossy, down], window: window, locale: english)
        XCTAssertTrue(broken.hasPrefix("iMac "), "最严重的排最前：\(broken)")
        XCTAssertFalse(broken.contains("AAPC"), "零星丢包不该挤掉真中断的位置：\(broken)")
    }

    /// 页面停在那里不动，图也得跟着走。表头的年龄在动而色带冻住，比整页都不动更误导。
    @MainActor
    func testTheOpenPageReloadsHistoryOnItsOwn() {
        let path = NSTemporaryDirectory() + "elink-mesh-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let mesh = MeshMonitor(store: UsageStore(path: path), lighthouseURL: nil)
        let model = MeshDetailModel()
        let first = model.anchor

        model.startAutoReload(mesh: mesh, interval: 0.05)
        defer { model.stopAutoReload() }
        let deadline = Date().addingTimeInterval(3)
        while model.anchor == first, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotEqual(model.anchor, first, "页面开着就该自己重载，不该只等用户点刷新")
    }

    /// 地址存在与否要能被视图观察到，横幅才切得回去。
    @MainActor
    func testConfiguredFlagFollowsTheLighthouseAddress() {
        let path = NSTemporaryDirectory() + "elink-mesh-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let mesh = MeshMonitor(store: UsageStore(path: path), lighthouseURL: nil)
        XCTAssertFalse(mesh.configured)

        // 用 discard 端口：reconfigure 会立刻拉一次名册，这个地址秒拒，测试不碰网络
        mesh.reconfigure(lighthouseURL: MeshMonitor.lighthouseURL(from: "127.0.0.1:9"))
        XCTAssertTrue(mesh.configured)
        mesh.stop()

        // 地址被清空后回到「未配置」，横幅不能停在上一次的说法
        mesh.reconfigure(lighthouseURL: MeshMonitor.lighthouseURL(from: ""))
        XCTAssertFalse(mesh.configured)
    }
}
