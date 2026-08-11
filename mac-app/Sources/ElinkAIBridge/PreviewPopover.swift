import AppKit
import SwiftUI

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = PanelModel()
    private let status: StatusService
    private let usage: UsageFetcher
    private let cluster: ClusterManager
    private let updater = UpdateChecker()
    private let link: LinkMonitor
    private let mesh: MeshMonitor
    private let port: UInt16
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var loadingPreview = false
    private var loadingSnapshot = false
    private var actionInFlight = false
    private let sessionMonitor = AgentSessionMonitor()
    private var loadingSessions = false

    init(status: StatusService, usage: UsageFetcher, cluster: ClusterManager,
         link: LinkMonitor, mesh: MeshMonitor, port: UInt16) {
        self.status = status
        self.usage = usage
        self.cluster = cluster
        self.link = link
        self.mesh = mesh
        self.port = port
        super.init()
        model.deviceConnectionEnabled = DeviceClient.isEnabled
        if !model.deviceConnectionEnabled {
            model.deviceSummary = tr("屏幕连接已关闭", "Screen Connection off")
            model.deviceBadge = tr("已关闭", "Off")
        }
        model.onSetMode = { [weak self] mode in
            Log.user("change device display mode to \(mode)")
            self?.performAction(tr("正在切换页面…", "Switching page…")) { DeviceClient.setMode(mode, completion: $0) }
        }
        model.onDeviceRefresh = { [weak self] kind in
            Log.user("refresh device display kind=\(kind)")
            self?.performAction(kind == "smart"
                ? tr("正在请求智能刷新…", "Requesting smart refresh…")
                : tr("正在请求完整刷新…", "Requesting full refresh…")) {
                DeviceClient.refresh(kind, completion: $0)
            }
        }
        model.onRefreshAll = { [weak self] in
            guard let self, !self.model.refreshingUsage else { return }
            Log.user("refresh provider usage")
            self.model.refreshingUsage = true
            self.model.updatedText = tr("正在刷新用量…", "Refreshing usage…")
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
            self.model.settingsMessage = enabled
                ? tr("屏幕连接已开启", "Screen Connection on")
                : tr("屏幕连接已关闭", "Screen Connection off")
            Log.user("device connection \(enabled ? "enabled" : "disabled")")
            if enabled {
                self.model.deviceSummary = tr("正在连接设备…", "Connecting device…")
                self.model.deviceBadge = tr("连接中", "Connecting")
                self.reload()
            } else {
                self.model.previewImage = nil
                self.model.deviceSummary = tr("屏幕连接已关闭", "Screen Connection off")
                self.model.deviceBadge = tr("已关闭", "Off")
                self.model.deviceHealthy = false
                self.model.busy = false
            }
        }
        model.onSaveHost = { [weak self] host in
            DeviceClient.host = DeviceClient.normalizedHost(host)
            Log.user("save device address \(DeviceClient.host)")
            self?.model.deviceHost = DeviceClient.host
            self?.model.settingsMessage = tr("地址已保存", "Address saved")
            self?.reload()
        }
        model.onAutoPair = { [weak self] in
            guard self?.model.deviceConnectionEnabled == true else { return }
            Log.user("start device auto-pair")
            self?.model.busy = true
            self?.model.settingsMessage = tr("正在查找屏幕…", "Searching for screen…")
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
                self.model.settingsMessage = found.map { tr("配对成功：\($0)", "Paired: \($0)") }
                    ?? tr("未找到屏幕，请确认树莓派与本机在同一局域网",
                          "No screen found. Make sure the Raspberry Pi and this host are on the same LAN")
                self.reload()
            }
        }
        model.onPointHere = { [weak self] in
            guard let self else { return }
            Log.user("set this host as device bridge")
            guard let ip = DeviceClient.localIPv4() else {
                Log.warning("set bridge failed: local IPv4 unavailable", category: "user")
                self.model.settingsMessage = tr("无法取得本机局域网地址", "Cannot get this host's LAN address")
                return
            }
            let url = "http://\(ip):\(self.port)"
            DeviceClient.setBridge(url) { [weak self] error in
                Log.user(
                    error.map { "set bridge failed: \($0.localizedDescription)" }
                        ?? "bridge set to \(url)",
                    level: error == nil ? .info : .warning
                )
                self?.model.settingsMessage = error.map {
                    tr("设置失败：\($0.localizedDescription)", "Setup failed: \($0.localizedDescription)")
                } ?? tr("桥接已设置，设备将从 \(url)/v1/status 拉取数据",
                        "Bridge set. The device will pull data from \(url)/v1/status")
            }
        }
        model.agentSessionsEnabled = AgentSessionMonitor.isEnabled
        model.onSetAgentSessionsEnabled = { [weak self] enabled in
            guard let self else { return }
            AgentSessionMonitor.isEnabled = enabled
            self.model.agentSessionsEnabled = enabled
            self.model.settingsMessage = enabled
                ? tr("Agent 会话显示已开启", "Agent sessions display on")
                : tr("Agent 会话显示已关闭", "Agent sessions display off")
            Log.user("agent sessions \(enabled ? "enabled" : "disabled")")
            if enabled {
                self.reloadAgentSessions()
            } else {
                self.model.agentSessions = []
            }
        }
        model.onSaveClaudeToken = { [weak self] value, completion in
            guard let self else { completion(false); return }
            guard let token = ElinkClaudeTokenStore.normalizedToken(value) else {
                self.model.settingsMessage = tr("Claude token 格式无效",
                                                "Invalid Claude token")
                completion(false)
                return
            }
            self.model.claudeCredentialValidating = true
            self.model.settingsMessage = tr("正在向 Claude 验证 token…",
                                            "Validating token with Claude…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let validation = UsageFetcher.validateClaudeToken(token)
                DispatchQueue.main.async {
                    guard let self else { completion(false); return }
                    self.model.claudeCredentialValidating = false
                    switch validation {
                    case let .success(usage):
                        do {
                            try ElinkClaudeTokenStore.shared.save(token)
                            self.model.claudeCredentialState = .configured
                            self.model.settingsMessage = tr("Claude 长期 token 已验证并保存到 Elink Keychain",
                                                            "Claude long-lived token validated and saved to the Elink Keychain")
                            Log.user("save validated Elink Claude credential")
                            self.usage.acceptValidatedClaudeUsage(usage)
                            self.reload()
                            completion(true)
                        } catch {
                            self.model.settingsMessage = tr("保存 Claude token 失败：\(error.localizedDescription)",
                                                            "Could not save Claude token: \(error.localizedDescription)")
                            Log.warning("save Elink Claude credential failed: \(error.localizedDescription)",
                                        category: "user")
                            completion(false)
                        }
                    case let .failure(error):
                        self.model.settingsMessage = error.localizedDescription
                        Log.warning("validate Elink Claude credential failed: \(error.localizedDescription)",
                                    category: "user")
                        completion(false)
                    }
                }
            }
        }
        model.onRemoveClaudeToken = { [weak self] in
            guard let self else { return false }
            do {
                try ElinkClaudeTokenStore.shared.remove()
                self.model.claudeCredentialState = .automatic
                self.model.settingsMessage = tr("已移除 Elink token，恢复自动发现 Claude 凭据",
                                                "Elink token removed; using automatic Claude credential discovery")
                Log.user("remove Elink Claude credential")
                self.refreshAfterClaudeCredentialChange()
                return true
            } catch {
                self.model.settingsMessage = tr("移除 Claude token 失败：\(error.localizedDescription)",
                                                "Could not remove Claude token: \(error.localizedDescription)")
                Log.warning("remove Elink Claude credential failed: \(error.localizedDescription)",
                            category: "user")
                return false
            }
        }
        model.onOpenDeviceStatus = { [weak self] in
            guard let base = DeviceClient.baseURL else {
                Log.warning("open device status failed: device address is not configured", category: "user")
                self?.model.settingsMessage = tr("请先设置屏幕地址", "Set the screen address first")
                return
            }
            Log.user("open device status page \(base.appendingPathComponent("v1/device").absoluteString)")
            NSWorkspace.shared.open(base.appendingPathComponent("v1/device"))
        }
        let hosting = NSHostingController(
            rootView: UsagePanelView(model: model, updater: updater, cluster: cluster,
                                     mesh: mesh)
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
        model.lighthouseURL = MeshMonitor.lighthouse
        model.onSaveLighthouse = { [weak self] text in
            Log.user("save nebula lighthouse address")
            MeshMonitor.lighthouse = text
            self?.model.lighthouseURL = text
            self?.mesh.reconfigure(lighthouseURL: MeshMonitor.lighthouseURL(from: text))
        }
        model.bridgeAddress = "http://\(DeviceClient.localIPv4() ?? "127.0.0.1"):\(port)/v1/status"
        model.settingsMessage = nil
        model.launchAtLogin = LaunchAtLogin.isEnabled()
        model.agentSessionsEnabled = AgentSessionMonitor.isEnabled
        do {
            model.claudeCredentialState = try ElinkClaudeTokenStore.shared.token() == nil
                ? .automatic : .configured
        } catch {
            model.claudeCredentialState = error as? ElinkClaudeTokenStoreError == .invalidToken
                ? .invalid : .unavailable
            model.settingsMessage = tr("读取 Elink Claude token 失败：\(error.localizedDescription)",
                                       "Could not read Elink's Claude token: \(error.localizedDescription)")
        }
        let visibleHeight = button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 724
        model.panelMaxHeight = max(320, visibleHeight - 24)
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
        // 常规节拍是 30 秒；打开时补一轮，第一眼的数字才不至于旧到一个节拍
        mesh.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionMonitor.reset()
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
        reloadAgentSessions()
        model.natObservation = link.observation
        model.natUnavailable = link.unavailable
        guard model.deviceConnectionEnabled else { return }
        reloadInfo()
        reloadPreview()
    }

    private func refreshAfterClaudeCredentialChange() {
        model.refreshingUsage = true
        usage.refresh(force: true) { [weak self] in
            guard let self else { return }
            self.model.refreshingUsage = false
            self.reload()
        }
    }

    private func reloadAgentSessions() {
        guard model.agentSessionsEnabled, !loadingSessions else { return }
        loadingSessions = true
        sessionMonitor.poll { [weak self] sessions in
            guard let self else { return }
            self.loadingSessions = false
            guard self.model.agentSessionsEnabled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.model.agentSessions = sessions
            }
        }
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
                self.model.deviceBadge = info.stale ? tr("数据陈旧", "Stale") : tr("在线", "Online")
                self.model.deviceHealthy = !info.stale
            case let .failure(error):
                self.model.deviceSummary = tr("设备离线 · \(error.localizedDescription)",
                                              "Device offline · \(error.localizedDescription)")
                self.model.deviceBadge = tr("离线", "Offline")
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
                self.model.deviceSummary = tr("操作失败 · \(error.localizedDescription)",
                                              "Action failed · \(error.localizedDescription)")
            } else {
                self.model.deviceSummary = tr("请求已发送，等待设备完成送屏…",
                                              "Request sent, waiting for the device to finish updating the screen…")
                self.reload()
            }
        }
    }

    static func updatedText(_ fetchedAt: Date?) -> String {
        guard let fetchedAt else { return tr("用量更新中…", "Updating usage…") }
        let age = Int(Date().timeIntervalSince(fetchedAt))
        return age < 5
            ? tr("用量刚刚更新", "Usage just updated")
            : tr("用量 \(formatAge(age))前更新", "Usage updated \(formatAge(age)) ago")
    }

    static func segment(for mode: String) -> Int {
        ["dashboard", "claude", "codex"].firstIndex(of: mode) ?? 0
    }

    static func deviceSummary(_ info: DeviceInfo) -> String {
        let connection = info.stale ? tr("数据陈旧", "Stale") : tr("设备在线", "Device online")
        let version = info.version.map { " v\($0)" } ?? ""
        let mode = ["dashboard": tr("双栏", "Dual"), "claude": "Claude", "codex": "Codex"][info.mode] ?? info.mode
        let refresh = ["full": tr("完整刷新", "Full refresh"),
                       "partial": tr("局部刷新", "Partial refresh"),
                       "none": tr("尚未刷新", "Not refreshed yet")][info.refreshKind]
            ?? info.refreshKind
        let age = info.lastRefreshAge.map { tr(" · \(formatAge($0))前送屏", " · pushed \(formatAge($0)) ago") } ?? ""
        if let error = info.error, !error.isEmpty {
            return "\(connection)\(version) · \(mode) · \(error)"
        }
        return "\(connection)\(version) · \(mode) · \(refresh)\(age)"
    }

    static func formatAge(_ seconds: Int) -> String {
        if seconds >= 3600 { return tr("\(seconds / 3600)小时", "\(seconds / 3600)h") }
        if seconds >= 60 { return tr("\(seconds / 60)分钟", "\(seconds / 60)min") }
        return tr("\(max(0, seconds))秒", "\(max(0, seconds))s")
    }
}
