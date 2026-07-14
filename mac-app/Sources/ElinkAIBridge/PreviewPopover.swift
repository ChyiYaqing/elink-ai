import AppKit
import SwiftUI

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = PanelModel()
    private let status: StatusService
    private let usage: UsageFetcher
    private let port: UInt16
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var loadingPreview = false
    private var loadingSnapshot = false
    private var actionInFlight = false

    init(status: StatusService, usage: UsageFetcher, port: UInt16) {
        self.status = status
        self.usage = usage
        self.port = port
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
        model.onSaveHost = { [weak self] host in
            DeviceClient.host = DeviceClient.normalizedHost(host)
            self?.model.deviceHost = DeviceClient.host
            self?.model.settingsMessage = "地址已保存"
            self?.reload()
        }
        model.onAutoPair = { [weak self] in
            self?.model.busy = true
            self?.model.settingsMessage = "正在查找屏幕…"
            DeviceClient.autoPair(progress: { [weak self] text in
                self?.model.settingsMessage = text
            }) { [weak self] found in
                self?.model.busy = false
                self?.model.deviceHost = DeviceClient.host
                self?.model.settingsMessage = found.map { "配对成功：\($0)" }
                    ?? "未找到屏幕，请确认树莓派与 Mac 在同一局域网"
                self?.reload()
            }
        }
        model.onPointHere = { [weak self] in
            guard let self else { return }
            guard let ip = DeviceClient.localIPv4() else {
                self.model.settingsMessage = "无法取得本机局域网地址"
                return
            }
            let url = "http://\(ip):\(self.port)"
            DeviceClient.setBridge(url) { [weak self] error in
                self?.model.settingsMessage = error.map { "设置失败：\($0.localizedDescription)" }
                    ?? "桥接已设置，设备将从 \(url)/v1/status 拉取数据"
            }
        }
        model.onOpenDeviceStatus = { [weak self] in
            guard let base = DeviceClient.baseURL else {
                self?.model.settingsMessage = "请先设置屏幕地址"
                return
            }
            NSWorkspace.shared.open(base.appendingPathComponent("v1/device"))
        }
        let hosting = NSHostingController(rootView: UsagePanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        model.deviceHost = DeviceClient.host
        model.bridgeAddress = "http://\(DeviceClient.localIPv4() ?? "127.0.0.1"):\(port)/v1/status"
        model.settingsMessage = nil
        model.launchAtLogin = LaunchAtLogin.isEnabled()
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
