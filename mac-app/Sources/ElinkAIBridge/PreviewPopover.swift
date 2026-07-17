import AppKit
import SwiftUI

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = PanelModel()
    private let status: StatusService
    private let usage: UsageFetcher
    private let cluster: ClusterManager
    private let updater = UpdateChecker()
    private let port: UInt16
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var loadingPreview = false
    private var loadingSnapshot = false
    private var actionInFlight = false

    init(status: StatusService, usage: UsageFetcher, cluster: ClusterManager, port: UInt16) {
        self.status = status
        self.usage = usage
        self.cluster = cluster
        self.port = port
        super.init()
        model.deviceConnectionEnabled = DeviceClient.isEnabled
        if !model.deviceConnectionEnabled {
            model.deviceSummary = "屏幕连接已关闭"
            model.deviceBadge = "已关闭"
        }
        model.onSetMode = { [weak self] mode in
            Log.user("change device display mode to \(mode)")
            self?.performAction("正在切换页面…") { DeviceClient.setMode(mode, completion: $0) }
        }
        model.onDeviceRefresh = { [weak self] kind in
            Log.user("refresh device display kind=\(kind)")
            self?.performAction(kind == "smart" ? "正在请求智能刷新…" : "正在请求完整刷新…") {
                DeviceClient.refresh(kind, completion: $0)
            }
        }
        model.onRefreshAll = { [weak self] in
            guard let self, !self.model.refreshingUsage else { return }
            Log.user("refresh provider usage")
            self.model.refreshingUsage = true
            self.model.updatedText = "正在刷新用量…"
            self.usage.refresh(force: true) { [weak self] in
                guard let self else { return }
                self.model.refreshingUsage = false
                self.reload()
            }
        }
        model.onSetDeviceConnectionEnabled = { [weak self] enabled in
            guard let self else { return }
            DeviceClient.isEnabled = enabled
            self.model.deviceConnectionEnabled = enabled
            self.model.settingsMessage = enabled ? "屏幕连接已开启" : "屏幕连接已关闭"
            Log.user("device connection \(enabled ? "enabled" : "disabled")")
            if enabled {
                self.model.deviceSummary = "正在连接设备…"
                self.model.deviceBadge = "连接中"
                self.reload()
            } else {
                self.model.previewImage = nil
                self.model.deviceSummary = "屏幕连接已关闭"
                self.model.deviceBadge = "已关闭"
                self.model.deviceHealthy = false
                self.model.busy = false
            }
        }
        model.onSaveHost = { [weak self] host in
            DeviceClient.host = DeviceClient.normalizedHost(host)
            Log.user("save device address \(DeviceClient.host)")
            self?.model.deviceHost = DeviceClient.host
            self?.model.settingsMessage = "地址已保存"
            self?.reload()
        }
        model.onAutoPair = { [weak self] in
            guard self?.model.deviceConnectionEnabled == true else { return }
            Log.user("start device auto-pair")
            self?.model.busy = true
            self?.model.settingsMessage = "正在查找屏幕…"
            DeviceClient.autoPair(progress: { [weak self] text in
                self?.model.settingsMessage = text
            }) { [weak self] found in
                guard let self else { return }
                self.model.busy = false
                guard self.model.deviceConnectionEnabled else { return }
                self.model.deviceHost = DeviceClient.host
                Log.user(
                    found.map { "device auto-pair succeeded: \($0)" }
                        ?? "device auto-pair failed: no device found",
                    level: found == nil ? .warning : .info
                )
                self.model.settingsMessage = found.map { "配对成功：\($0)" }
                    ?? "未找到屏幕，请确认树莓派与 Mac 在同一局域网"
                self.reload()
            }
        }
        model.onPointHere = { [weak self] in
            guard let self else { return }
            Log.user("set this Mac as device bridge")
            guard let ip = DeviceClient.localIPv4() else {
                Log.warning("set bridge failed: local IPv4 unavailable", category: "user")
                self.model.settingsMessage = "无法取得本机局域网地址"
                return
            }
            let url = "http://\(ip):\(self.port)"
            DeviceClient.setBridge(url) { [weak self] error in
                Log.user(
                    error.map { "set bridge failed: \($0.localizedDescription)" }
                        ?? "bridge set to \(url)",
                    level: error == nil ? .info : .warning
                )
                self?.model.settingsMessage = error.map { "设置失败：\($0.localizedDescription)" }
                    ?? "桥接已设置，设备将从 \(url)/v1/status 拉取数据"
            }
        }
        model.onOpenDeviceStatus = { [weak self] in
            guard let base = DeviceClient.baseURL else {
                Log.warning("open device status failed: device address is not configured", category: "user")
                self?.model.settingsMessage = "请先设置屏幕地址"
                return
            }
            Log.user("open device status page \(base.appendingPathComponent("v1/device").absoluteString)")
            NSWorkspace.shared.open(base.appendingPathComponent("v1/device"))
        }
        let hosting = NSHostingController(
            rootView: UsagePanelView(model: model, updater: updater, cluster: cluster)
        )
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            Log.user("close menu panel")
            popover.performClose(nil)
            return
        }
        Log.user("open menu panel")
        model.deviceConnectionEnabled = DeviceClient.isEnabled
        model.deviceHost = DeviceClient.host
        model.bridgeAddress = "http://\(DeviceClient.localIPv4() ?? "127.0.0.1"):\(port)/v1/status"
        model.settingsMessage = nil
        model.launchAtLogin = LaunchAtLogin.isEnabled()
        updater.checkAutomaticallyIfNeeded()
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
        guard model.deviceConnectionEnabled else { return }
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
            guard self.model.deviceConnectionEnabled else { return }
            if case let .success(data) = result, let image = NSImage(data: data) {
                self.model.previewImage = image
            }
        }
    }

    private func reloadInfo() {
        DeviceClient.fetchInfo { [weak self] result in
            guard let self, self.model.deviceConnectionEnabled,
                  !self.actionInFlight else { return }
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
        guard model.deviceConnectionEnabled, !actionInFlight else { return }
        actionInFlight = true
        model.busy = true
        model.deviceSummary = progress
        action { [weak self] error in
            guard let self else { return }
            self.actionInFlight = false
            self.model.busy = false
            guard self.model.deviceConnectionEnabled else { return }
            if let error {
                Log.warning("device action failed: \(error.localizedDescription)", category: "user")
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
        let version = info.version.map { " v\($0)" } ?? ""
        let mode = ["dashboard": "双栏", "claude": "Claude", "codex": "Codex"][info.mode] ?? info.mode
        let refresh = ["full": "完整刷新", "partial": "局部刷新", "none": "尚未刷新"][info.refreshKind]
            ?? info.refreshKind
        let age = info.lastRefreshAge.map { " · \(formatAge($0))前送屏" } ?? ""
        if let error = info.error, !error.isEmpty {
            return "\(connection)\(version) · \(mode) · \(error)"
        }
        return "\(connection)\(version) · \(mode) · \(refresh)\(age)"
    }

    static func formatAge(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)小时" }
        if seconds >= 60 { return "\(seconds / 60)分钟" }
        return "\(max(0, seconds))秒"
    }
}
