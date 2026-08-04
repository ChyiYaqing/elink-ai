import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ElinkAIBridge

final class UsagePanelViewTests: XCTestCase {
    // 断言依赖中文文案；语言默认跟随系统，这里固定为中文保证在英文系统的 CI 上稳定
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    func testClusterFeedbackFollowsCurrentBackgroundSyncState() {
        let failure = "同步失败：节点认证失败"

        XCTAssertEqual(
            UsagePanelView.clusterFeedbackMessage(
                transient: failure,
                currentError: "节点认证失败"
            ),
            failure
        )
        XCTAssertNil(UsagePanelView.clusterFeedbackMessage(
            transient: failure,
            currentError: nil
        ))
        XCTAssertEqual(
            UsagePanelView.clusterFeedbackMessage(
                transient: "同步完成",
                currentError: nil
            ),
            "同步完成"
        )
        XCTAssertEqual(
            UsagePanelView.clusterFeedbackMessage(
                transient: "同步完成",
                currentError: "节点已离线"
            ),
            "同步失败：节点已离线"
        )
        XCTAssertNil(UsagePanelView.clusterFeedbackMessage(
            transient: "连接失败：请求超时",
            currentError: nil
        ))
        XCTAssertEqual(
            UsagePanelView.clusterFeedbackMessage(
                transient: "配对失败：配对码已过期",
                currentError: nil
            ),
            "配对失败：配对码已过期"
        )
    }

    func testCompatiblePairingPeerIsPreferredOverEarlierLegacyPeer() {
        let legacy = DiscoveredClusterPeer(
            nodeID: "legacy", name: "A Legacy", endpoint: "http://legacy:8765",
            clusterID: nil, pairable: true, pairingProtocol: 2
        )
        let compatible = DiscoveredClusterPeer(
            nodeID: "current", name: "B Current", endpoint: "http://current:8765",
            clusterID: nil, pairable: true,
            pairingProtocol: DiscoveredClusterPeer.currentPairingProtocol
        )

        XCTAssertEqual(
            UsagePanelView.preferredPairingPeer(in: [legacy, compatible])?.nodeID,
            "current"
        )
    }

    @MainActor
    func testAgentSessionsCardDefaultsCollapsedAndExpandedRowsIncreaseHeight() {
        let session = AgentSession(
            id: "session-1",
            kind: .claude,
            title: "elink-ai",
            snippet: "修复弹窗布局",
            model: "claude-opus",
            lastModified: Date()
        )

        func height(initiallyExpanded: Bool = false) -> CGFloat {
            let host = NSHostingView(rootView: AgentSessionsCard(
                sessions: [session],
                theme: PanelTheme(.light),
                initiallyExpanded: initiallyExpanded
            ))
            host.frame = NSRect(x: 0, y: 0, width: 408, height: 1)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        XCTAssertGreaterThan(height(initiallyExpanded: true), height())
    }

    @MainActor
    func testDashboardHeightIsCappedAndMainContentScrolls() {
        let path = NSTemporaryDirectory() + "elink-panel-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let cluster = ClusterManager(store: store, credentials: ClusterCredentials(
            nodeID: "local-node",
            nodeName: "Local Mac",
            clusterID: nil,
            clusterSecret: nil,
            timezone: nil
        ))
        let model = PanelModel()
        model.panelMaxHeight = 320
        let view = UsagePanelView(
            model: model,
            updater: UpdateChecker(currentVersion: "0.1.20"),
            cluster: cluster,
            mesh: MeshMonitor(store: store, lighthouseURL: nil)
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(size.height, 320)
        XCTAssertTrue(host.descendants.contains { $0 is NSScrollView })
    }

    @MainActor
    func testEnglishStatsRangePickerFitsNarrowCard() throws {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        // 渲染会读库：注入临时库，测试不碰用户的真实数据库
        let path = NSTemporaryDirectory() + "elink-stats-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let view = UsageStatsView(
            provider: "codex",
            title: "Codex",
            pet: PixelPet.codex,
            accent: PanelTheme.codexColor(dark: false),
            theme: PanelTheme(.light),
            clusterNodes: [],
            store: UsageStore(path: path),
            onBack: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 384, height: 500)
        host.layoutSubtreeIfNeeded()

        let picker = try XCTUnwrap(
            host.descendants.compactMap { $0 as? NSSegmentedControl }.first
        )
        let pickerFrame = host.convert(picker.bounds, from: picker)
        XCTAssertGreaterThanOrEqual(pickerFrame.minX, host.bounds.minX)
        XCTAssertLessThanOrEqual(pickerFrame.maxX, host.bounds.maxX)
    }

    @MainActor
    func testScreenConnectionSettingsAreCollapsedByDefault() {
        XCTAssertFalse(deviceSettingsPlaceholders(
            enabled: true,
            expanded: false
        ).contains("例如 192.168.1.50:8766"))
        XCTAssertFalse(deviceSettingsPlaceholders(
            enabled: false,
            expanded: true
        ).contains("例如 192.168.1.50:8766"))
    }

    @MainActor
    func testExpandedScreenConnectionSettingsShowDeviceAddressControls() {
        XCTAssertTrue(deviceSettingsPlaceholders(
            enabled: true,
            expanded: true
        ).contains("例如 192.168.1.50:8766"))
    }

    @MainActor
    private func deviceSettingsPlaceholders(enabled: Bool, expanded: Bool) -> [String] {
        let path = NSTemporaryDirectory() + "elink-panel-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let cluster = ClusterManager(store: store, credentials: ClusterCredentials(
            nodeID: "local-node",
            nodeName: "Local Mac",
            clusterID: nil,
            clusterSecret: nil,
            timezone: nil
        ))
        let model = PanelModel()
        model.showSettings = true
        model.deviceConnectionEnabled = enabled
        let view = UsagePanelView(
            model: model,
            updater: UpdateChecker(currentVersion: "0.1.20"),
            cluster: cluster,
            mesh: MeshMonitor(store: store, lighthouseURL: nil),
            initialDeviceSettingsExpanded: expanded
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        host.layoutSubtreeIfNeeded()

        return host.descendants
            .compactMap { ($0 as? NSTextField)?.placeholderString }
    }

    /// Nebula 那一页现在开在面板里，和用量统计一样是一层覆盖。它原先是 720pt 宽的
    /// 独立窗口，搬进 440pt 的面板后，页面上的控件不能越出面板宽度。
    @MainActor
    func testMeshPageOpensInsideThePanelAndFitsItsWidth() {
        let path = NSTemporaryDirectory() + "elink-panel-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let cluster = ClusterManager(store: store, credentials: ClusterCredentials(
            nodeID: "local-node",
            nodeName: "Local Mac",
            clusterID: nil,
            clusterSecret: nil,
            timezone: nil
        ))
        let model = PanelModel()
        model.showMesh = true
        let view = UsagePanelView(
            model: model,
            updater: UpdateChecker(currentVersion: "0.1.20"),
            cluster: cluster,
            mesh: MeshMonitor(store: store, lighthouseURL: nil)
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        host.layoutSubtreeIfNeeded()

        let placeholders = host.descendants
            .compactMap { ($0 as? NSTextField)?.placeholderString }
        XCTAssertTrue(
            placeholders.contains { $0.contains("lighthouse 地址") },
            "面板里应直接显示 Nebula 页面，实际输入框：\(placeholders)"
        )
        for view in host.descendants
            where view is NSTextField || view is NSSegmentedControl {
            let frame = host.convert(view.bounds, from: view)
            XCTAssertGreaterThanOrEqual(frame.minX, host.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX)
        }
    }

    @MainActor
    func testSingleNodeClusterShowsPairingCodeInput() {
        let path = NSTemporaryDirectory() + "elink-panel-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        let cluster = ClusterManager(store: store, credentials: ClusterCredentials(
            nodeID: "local-node",
            nodeName: "Local Mac",
            clusterID: "cluster-test",
            clusterSecret: Data(repeating: 1, count: 32).base64EncodedString(),
            timezone: "Asia/Singapore"
        ))
        let model = PanelModel()
        model.showSettings = true
        let view = UsagePanelView(
            model: model,
            updater: UpdateChecker(currentVersion: "0.1.20"),
            cluster: cluster,
            mesh: MeshMonitor(store: store, lighthouseURL: nil),
            initialClusterExpanded: true
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        host.layoutSubtreeIfNeeded()

        let placeholders = host.descendants
            .compactMap { ($0 as? NSTextField)?.placeholderString }
        XCTAssertTrue(
            placeholders.contains { $0.contains("配对码，例如 ABCD-EFGH-JKMN-PQRS") },
            "单节点集群应直接显示新版配对码输入框，实际输入框：\(placeholders)"
        )
        // 界面上不允许再出现旧版 6 位配对码的文案
        let texts = host.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(
            (texts + placeholders).contains { $0.contains("6 位") },
            "仍有旧版 6 位配对码文案残留"
        )
    }

    func testClusterNodeDetailsResolveAddressForRemoteAndLocalNodes() {
        let remote = UsagePanelView.clusterNodeDetails(
            ClusterNodeRecord(nodeID: "node-b", name: "Studio",
                              endpoint: "http://10.1.7.106:8765",
                              lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                              lastSyncAt: nil),
            isLocal: false, localEndpoint: "http://192.168.1.2:8765", peers: []
        ).map(\.value)
        XCTAssertEqual(remote.first, "http://10.1.7.106:8765")
        XCTAssertTrue(remote.contains("node-b"), "详情应包含节点 ID，实际：\(remote)")
        XCTAssertTrue(remote.contains("尚未同步"), "从未同步的节点应说明未同步，实际：\(remote)")

        // 尚未记录 endpoint 时回落到 Bonjour 发现结果
        let discovered = UsagePanelView.clusterNodeDetails(
            ClusterNodeRecord(nodeID: "node-b", name: "Studio", endpoint: nil,
                              lastSeenAt: nil, lastSyncAt: nil),
            isLocal: false, localEndpoint: nil,
            peers: [DiscoveredClusterPeer(nodeID: "node-b", name: "Studio",
                                          endpoint: "http://10.1.7.9:8765",
                                          clusterID: "cluster-test", pairable: false)]
        ).map(\.value)
        XCTAssertEqual(discovered.first, "http://10.1.7.9:8765")

        // 本机节点记录不含 endpoint，改用局域网地址
        let local = UsagePanelView.clusterNodeDetails(
            ClusterNodeRecord(nodeID: "local-node", name: "Air", endpoint: nil,
                              lastSeenAt: Date(), lastSyncAt: nil),
            isLocal: true, localEndpoint: "http://192.168.1.2:8765", peers: []
        ).map(\.value)
        XCTAssertEqual(local, ["http://192.168.1.2:8765", "local-node"])
    }

    @MainActor
    func testTappedClusterNodeRevealsConnectionDetail() {
        let path = NSTemporaryDirectory() + "elink-panel-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = UsageStore(path: path)
        store.upsertClusterNode(ClusterNodeRecord(
            nodeID: "node-b", name: "Studio",
            endpoint: "http://10.1.7.106:8765",
            lastSeenAt: Date(), lastSyncAt: Date()
        ))
        let cluster = ClusterManager(store: store, credentials: ClusterCredentials(
            nodeID: "local-node",
            nodeName: "Local Host",
            clusterID: "cluster-test",
            clusterSecret: Data(repeating: 1, count: 32).base64EncodedString(),
            timezone: "Asia/Singapore"
        ))

        func clusterCardHeight(expandedNodeID: String?) -> CGFloat {
            let model = PanelModel()
            model.showSettings = true
            model.panelMaxHeight = 3000
            let view = UsagePanelView(
                model: model,
                updater: UpdateChecker(currentVersion: "0.1.20"),
                cluster: cluster,
                mesh: MeshMonitor(store: store, lighthouseURL: nil),
                initialClusterExpanded: true,
                initialExpandedNodeID: expandedNodeID
            )
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 1)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        XCTAssertGreaterThan(clusterCardHeight(expandedNodeID: "node-b"),
                             clusterCardHeight(expandedNodeID: nil),
                             "点击节点后应展开连接信息，面板应变高")
        XCTAssertEqual(clusterCardHeight(expandedNodeID: "missing-node"),
                       clusterCardHeight(expandedNodeID: nil),
                       "只有被点击的节点会展开")
    }

    /// 这套颜色存在的理由就是「同一屏上分得开」。先试过按 nodeID 哈希取色，实测
    /// 四台机器里三台撞成同一个颜色——6 个色位下四台不撞的概率只有 28%。
    func testEveryClusterMemberGetsADistinctColor() {
        let nodes = [
            "8469bfa8-c559-4a3b-8760-f7a594ca2ae8", // MacBook Air
            "68aac07c-8e0d-4450-9e56-1434d18affed", // Mac mini
            "b3b60b6b-56c2-4183-85f5-d568f070373e", // iMac
            "fb4beca5-6318-48c1-8382-ba2fa371a9a4", // 3BP
        ]
        let colors = UsageStats.deviceColors(for: nodes)
        XCTAssertEqual(colors.count, nodes.count)
        XCTAssertEqual(Set(colors.values).count, nodes.count, "四台设备必须四个颜色")

        // 传入顺序不影响分配：每台主机排出来的结果要一致，跨屏对照才成立
        XCTAssertEqual(UsageStats.deviceColors(for: nodes.reversed()), colors)
        XCTAssertEqual(UsageStats.deviceColors(for: nodes + nodes), colors, "重复项不占色位")
        for color in colors.values {
            XCTAssertTrue(UsageStats.devicePalette.contains(color))
        }

        // 花名册之外的来源仍要有个稳定颜色，而不是每次重绘都在变
        XCTAssertEqual(UsageStats.fallbackDeviceColor("stranger"),
                       UsageStats.fallbackDeviceColor("stranger"))
        XCTAssertEqual(UsageStats.fallbackDeviceColor(nil), UsageStats.devicePalette[0])
    }

    /// Codex 常常只有一台机器在用。以前要求「至少两台有数据」，于是这一块整个消失，
    /// 而「数据源」筛选器还在——页面一边说这是多机环境一边不给分布。一张 100% 的
    /// 卡片是明确回答：其余机器没用过。
    func testDeviceShareAppearsEvenWhenOnlyOneHostHasUsage() {
        XCTAssertTrue(UsageStats.showsDeviceShare(
            clusterNodes: 2, filteredToOneHost: false, devicesWithUsage: 1
        ), "只有一台有用量也要显示，这正是 Codex 的常态")
        XCTAssertTrue(UsageStats.showsDeviceShare(
            clusterNodes: 2, filteredToOneHost: false, devicesWithUsage: 2
        ))
        // 没组集群时没有「别的机器」可言
        XCTAssertFalse(UsageStats.showsDeviceShare(
            clusterNodes: 1, filteredToOneHost: false, devicesWithUsage: 1
        ))
        // 已经筛到单台，占比只会是 100%，是同义反复
        XCTAssertFalse(UsageStats.showsDeviceShare(
            clusterNodes: 2, filteredToOneHost: true, devicesWithUsage: 1
        ))
        // 该时段谁都没用过，空区块没有意义
        XCTAssertFalse(UsageStats.showsDeviceShare(
            clusterNodes: 2, filteredToOneHost: false, devicesWithUsage: 0
        ))
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
