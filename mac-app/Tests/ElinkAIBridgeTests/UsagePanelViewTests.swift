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
            updater: UpdateChecker(currentVersion: "0.1.17-rc5"),
            cluster: cluster,
            mesh: MeshMonitor(store: UsageStore.shared, lighthouseURL: nil)
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
        let view = UsageStatsView(
            provider: "codex",
            title: "Codex",
            pet: PixelPet.codex,
            accent: PanelTheme.codexColor(dark: false),
            theme: PanelTheme(.light),
            clusterNodes: [],
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
            updater: UpdateChecker(currentVersion: "0.1.17-rc5"),
            cluster: cluster,
            mesh: MeshMonitor(store: UsageStore.shared, lighthouseURL: nil),
            initialDeviceSettingsExpanded: expanded
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        host.layoutSubtreeIfNeeded()

        return host.descendants
            .compactMap { ($0 as? NSTextField)?.placeholderString }
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
            updater: UpdateChecker(currentVersion: "0.1.17-rc5"),
            cluster: cluster,
            mesh: MeshMonitor(store: UsageStore.shared, lighthouseURL: nil),
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
                updater: UpdateChecker(currentVersion: "0.1.17-rc5"),
                cluster: cluster,
                mesh: MeshMonitor(store: UsageStore.shared, lighthouseURL: nil),
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
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
