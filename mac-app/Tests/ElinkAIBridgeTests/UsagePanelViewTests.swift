import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ElinkAIBridge

final class UsagePanelViewTests: XCTestCase {
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
            updater: UpdateChecker(currentVersion: "0.1.15-rc1"),
            cluster: cluster,
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
            updater: UpdateChecker(currentVersion: "0.1.15-rc1"),
            cluster: cluster,
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
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
