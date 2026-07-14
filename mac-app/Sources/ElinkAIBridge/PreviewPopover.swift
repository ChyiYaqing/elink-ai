import AppKit
import SwiftUI

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = PanelModel()
    private let status: StatusService
    private let usage: UsageFetcher
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var loadingPreview = false
    private var loadingSnapshot = false
    private var actionInFlight = false

    init(status: StatusService, usage: UsageFetcher) {
        self.status = status
        self.usage = usage
        super.init()
        model.onSetMode = { [weak self] mode in
            self?.performAction("正在切换页面…") { DeviceClient.setMode(mode, completion: $0) }
        }
        model.onDeviceRefresh = { [weak self] kind in
            self?.performAction(kind == "smart" ? "正在请求智能刷新…" : "正在请求完整刷新…") {
                DeviceClient.refresh(kind, completion: $0)
            }
        }
        model.onRefreshAll = { [weak self] in
            self?.usage.refresh()
            self?.reload()
        }
        let hosting = NSHostingController(rootView: UsagePanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // .accessory 应用弹出时未被激活，transient 不会因外部点击自动关闭，需手动监听
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        startPolling()
        reload()
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        reloadSnapshot()
        reloadInfo()
        reloadPreview()
    }

    private func reloadSnapshot() {
        guard !loadingSnapshot else { return }
        loadingSnapshot = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let snapshot = self.status.snapshot()
            DispatchQueue.main.async {
                self.loadingSnapshot = false
                withAnimation(.easeOut(duration: 0.3)) {
                    self.model.claude = snapshot.claude
                    self.model.codex = snapshot.codex
                }
                self.model.updatedText = Self.updatedText(snapshot.usageFetchedAt)
            }
        }
    }

    private func reloadPreview() {
        guard !loadingPreview else { return }
        loadingPreview = true
        DeviceClient.fetchPreview { [weak self] result in
            guard let self else { return }
            self.loadingPreview = false
            if case let .success(data) = result, let image = NSImage(data: data) {
                self.model.previewImage = image
            }
        }
    }

    private func reloadInfo() {
        DeviceClient.fetchInfo { [weak self] result in
            guard let self, !self.actionInFlight else { return }
            switch result {
            case let .success(info):
                self.model.mode = info.mode
                self.model.deviceSummary = Self.deviceSummary(info)
                self.model.deviceBadge = info.stale ? "数据陈旧" : "在线"
                self.model.deviceHealthy = !info.stale
            case let .failure(error):
                self.model.deviceSummary = "设备离线 · \(error.localizedDescription)"
                self.model.deviceBadge = "离线"
                self.model.deviceHealthy = false
            }
        }
    }

    private func performAction(_ progress: String,
                               action: (@escaping (Error?) -> Void) -> Void) {
        guard !actionInFlight else { return }
        actionInFlight = true
        model.busy = true
        model.deviceSummary = progress
        action { [weak self] error in
            guard let self else { return }
            self.actionInFlight = false
            self.model.busy = false
            if let error {
                self.model.deviceSummary = "操作失败 · \(error.localizedDescription)"
            } else {
                self.model.deviceSummary = "请求已发送，等待设备完成送屏…"
                self.reload()
            }
        }
    }

    static func updatedText(_ fetchedAt: Date?) -> String {
        guard let fetchedAt else { return "用量更新中…" }
        let age = Int(Date().timeIntervalSince(fetchedAt))
        return age < 5 ? "用量刚刚更新" : "用量 \(formatAge(age))前更新"
    }

    static func segment(for mode: String) -> Int {
        ["dashboard", "claude", "codex"].firstIndex(of: mode) ?? 0
    }

    static func deviceSummary(_ info: DeviceInfo) -> String {
        let connection = info.stale ? "数据陈旧" : "设备在线"
        let mode = ["dashboard": "双栏", "claude": "Claude", "codex": "Codex"][info.mode] ?? info.mode
        let refresh = ["full": "完整刷新", "partial": "局部刷新", "none": "尚未刷新"][info.refreshKind]
            ?? info.refreshKind
        let age = info.lastRefreshAge.map { " · \(formatAge($0))前送屏" } ?? ""
        if let error = info.error, !error.isEmpty {
            return "\(connection) · \(mode) · \(error)"
        }
        return "\(connection) · \(mode) · \(refresh)\(age)"
    }

    static func formatAge(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)小时" }
        if seconds >= 60 { return "\(seconds / 60)分钟" }
        return "\(max(0, seconds))秒"
    }
}
