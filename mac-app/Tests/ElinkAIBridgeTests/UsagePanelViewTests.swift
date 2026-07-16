import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ElinkAIBridge

final class UsagePanelViewTests: XCTestCase {
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
            updater: UpdateChecker(currentVersion: "0.1.7"),
            cluster: cluster,
            initialClusterExpanded: true
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        host.layoutSubtreeIfNeeded()

        let placeholders = host.descendants
            .compactMap { ($0 as? NSTextField)?.placeholderString }
        XCTAssertTrue(
            placeholders.contains { $0.contains("6 位配对码") },
            "单节点集群应直接显示配对码输入框，实际输入框：\(placeholders)"
        )
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
