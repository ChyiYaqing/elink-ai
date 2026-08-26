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
    private let kiwi: KiwiVMMonitor
    private let port: UInt16
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    private var loadingPreview = false
    private var loadingSnapshot = false
    private var actionInFlight = false
    private let sessionMonitor = AgentSessionMonitor()
    private var loadingSessions = false

    init(status: StatusService, usage: UsageFetcher, cluster: ClusterManager,
         link: LinkMonitor, mesh: MeshMonitor, kiwi: KiwiVMMonitor, port: UInt16) {
        self.status = status
        self.usage = usage
        self.cluster = cluster
        self.link = link
        self.mesh = mesh
        self.kiwi = kiwi
        self.port = port
        super.init()
        model.vpsServers = KiwiVMCredentialStore.shared.servers()
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
        model.onSaveVPS = { [weak self] veid, label, apiKey, completion in
            self?.saveVPSCredential(veid: veid, label: label, apiKey: apiKey,
                                    completion: completion)
        }
        model.onRemoveVPS = { [weak self] veid in self?.removeVPSCredential(veid: veid) }
        let hosting = NSHostingController(
            rootView: UsagePanelView(model: model, updater: updater, cluster: cluster,
                                     mesh: mesh, kiwi: kiwi)
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
        // KiwiVM 的调用是计量的，所以它只在面板开着时跑：没人在看的时候读一次 VPS
        // 状态，换不回任何东西，却实实在在花掉一次配额。
        model.vpsServers = KiwiVMCredentialStore.shared.servers()
        kiwi.start()
        kiwi.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionMonitor.reset()
        kiwi.stop()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    /// 先向 KiwiVM 验证再落盘，与保存 Claude token 是同一套纪律：写进 Keychain 的
    /// 凭据必须是已知可用的，否则用户要等到下一个轮询周期才发现自己粘错了一个字符。
    /// 验证用的那次响应直接上屏，既省一次计量调用，也让第一行数字立刻出现。
    private func saveVPSCredential(veid: String, label: String, apiKey: String,
                                   completion: @escaping (Bool) -> Void) {
        guard let veid = KiwiVMCredentialStore.normalizedVeid(veid) else {
            model.settingsMessage = KiwiVMCredentialError.invalidVeid.errorDescription
            completion(false)
            return
        }
        guard let key = KiwiVMCredentialStore.normalizedApiKey(apiKey) else {
            model.settingsMessage = KiwiVMCredentialError.invalidApiKey.errorDescription
            completion(false)
            return
        }
        let credential = VpsCredential(
            veid: veid,
            label: KiwiVMCredentialStore.normalizedLabel(label, veid: veid),
            apiKey: key
        )
        model.vpsSaving = true
        model.settingsMessage = tr("正在向 KiwiVM 验证…", "Validating with KiwiVM…")
        kiwi.probe(credential: credential) { [weak self] result in
            guard let self else { completion(false); return }
            self.model.vpsSaving = false
            switch result {
            case .success:
                do {
                    try KiwiVMCredentialStore.shared.save(credential)
                    self.model.vpsServers = KiwiVMCredentialStore.shared.servers()
                    self.kiwi.reconfigure(credentials: KiwiVMCredentialStore.shared.load())
                    self.model.settingsMessage = tr("\(credential.label) 已验证并保存",
                                                    "\(credential.label) validated and saved")
                    Log.user("save kiwivm credential veid=\(veid)")
                    completion(true)
                } catch {
                    self.model.settingsMessage = error.localizedDescription
                    Log.warning("save kiwivm credential veid=\(veid) failed: \(error.localizedDescription)",
                                category: "kiwivm")
                    completion(false)
                }
            case let .failure(error):
                self.model.settingsMessage = Self.vpsProbeMessage(error)
                Log.warning("validate kiwivm credential veid=\(veid) failed: \(error)",
                            category: "kiwivm")
                completion(false)
            }
        }
    }

    static func vpsProbeMessage(_ error: VpsFetchError) -> String {
        switch error {
        case .rejected:
            return tr("KiwiVM 拒绝了这组 VM ID 和 API key，请核对后重试",
                      "KiwiVM rejected this VM ID and API key; check them and try again")
        case .unreachable:
            return tr("连不上 KiwiVM，请稍后重试", "Cannot reach KiwiVM; try again shortly")
        case .malformed:
            return tr("KiwiVM 返回了看不懂的内容", "KiwiVM returned something unreadable")
        }
    }

    private func removeVPSCredential(veid: String) {
        do {
            try KiwiVMCredentialStore.shared.remove(veid: veid)
            model.vpsServers = KiwiVMCredentialStore.shared.servers()
            kiwi.reconfigure(credentials: KiwiVMCredentialStore.shared.load())
            model.settingsMessage = tr("已移除该服务器的 API key",
                                       "The server's API key has been removed")
            Log.user("remove kiwivm credential veid=\(veid)")
        } catch {
            model.settingsMessage = error.localizedDescription
            Log.warning("remove kiwivm credential veid=\(veid) failed: \(error.localizedDescription)",
                        category: "kiwivm")
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
            // 快照先取：它顺带把当天的用量落库，成本汇总紧接着读的就是这一份
            let snapshot = self.status.snapshot()
            let costs = Self.costSummaries()
            DispatchQueue.main.async {
                self.loadingSnapshot = false
                withAnimation(.easeOut(duration: 0.3)) {
                    self.model.claude = snapshot.claude
                    self.model.codex = snapshot.codex
                    self.model.claudeCost = costs.claude
                    self.model.codexCost = costs.codex
                }
                self.model.updatedText = Self.updatedText(snapshot.usageFetchedAt)
            }
        }
    }

    /// 两家 provider 的成本汇总。定价表只读一次：它要落一次盘，两张卡片各读一遍
    /// 是白读的。
    private static func costSummaries() -> (claude: CostSummary, codex: CostSummary) {
        let now = Date()
        let since = StatusService.dayKey(
            StatusService.aggregationCalendar.date(byAdding: .day, value: -29, to: now) ?? now)
        let table = Pricing.table()
        func summary(_ provider: String) -> CostSummary {
            UsageStats.costSummary(
                rows: UsageStore.shared.modelCategoryUsage(provider: provider, since: since),
                now: now, table: table)
        }
        return (summary("claude"), summary("codex"))
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
                self.model.showsMonitor = info.showsMonitor
                self.model.deviceSummary = Self.deviceSummary(info)
                self.model.deviceBadge = info.showsMonitor
                    ? tr("监控页", "Monitor")
                    : (info.stale ? tr("数据陈旧", "Stale") : tr("在线", "Online"))
                self.model.deviceHealthy = !info.stale
            case let .failure(error):
                self.model.deviceSummary = tr("设备离线 · \(error.localizedDescription)",
                                              "Device offline · \(error.localizedDescription)")
                self.model.deviceBadge = tr("离线", "Offline")
                self.model.deviceHealthy = false
                self.model.showsMonitor = false
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
        // 屏幕停在监控页时报 mode 是错的：那是用量面板的排版，跟屏上正显示的东西无关
        let mode = info.showsMonitor
            ? tr("设备监控", "Device Monitor")
            : (["dashboard": tr("双栏", "Dual"), "claude": "Claude", "codex": "Codex"][info.mode] ?? info.mode)
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
