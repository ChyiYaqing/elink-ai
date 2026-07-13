import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let preview = PreviewPopoverController()
    private let usage: UsageFetcher
    private let port: UInt16
    private let claude = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codex = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let device = NSMenuItem(title: "屏幕：未设置", action: nil, keyEquivalent: "")
    private var modeItems = [String: NSMenuItem]()

    init(usage: UsageFetcher, port: UInt16) {
        self.usage = usage; self.port = port
        super.init(); build()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Elink AI")
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        usage.onUpdate = { [weak self] in self?.refreshUsage() }
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            item.menu = menu; button.performClick(nil); item.menu = nil
        } else { preview.toggle(relativeTo: button) }
    }

    private func build() {
        menu.delegate = self
        claude.isEnabled = false; codex.isEnabled = false; device.isEnabled = false
        menu.addItem(claude); menu.addItem(codex); menu.addItem(.separator()); menu.addItem(device)
        menu.addItem(action("自动查找并配对屏幕", #selector(pair)))
        menu.addItem(action("设置屏幕地址…", #selector(setAddress)))
        menu.addItem(action("打开设备状态", #selector(openDeviceStatus)))
        let modes = NSMenu()
        for (title, mode) in [("双栏：Claude + Codex", "dashboard"),
                              ("仅 Claude", "claude"), ("仅 Codex", "codex")] {
            let value = action(title, #selector(setMode(_:))); value.representedObject = mode
            modeItems[mode] = value; modes.addItem(value)
        }
        let mode = NSMenuItem(title: "屏幕页面", action: nil, keyEquivalent: ""); mode.submenu = modes
        menu.addItem(mode)
        menu.addItem(action("智能刷新", #selector(smartRefresh)))
        menu.addItem(action("完整刷新", #selector(fullRefresh)))
        menu.addItem(action("把本机设为数据桥接", #selector(pointHere)))
        menu.addItem(action("显示桥接服务地址", #selector(showBridgeAddress)))
        menu.addItem(.separator()); menu.addItem(action("刷新全部状态", #selector(refreshAll), key: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) { refreshAll() }

    @objc private func refreshAll() { usage.refresh(); refreshUsage(); refreshDevice() }
    private func refreshUsage() {
        claude.title = Self.usageLine("Claude", usage.claude)
        codex.title = Self.usageLine("Codex", usage.codex)
    }
    static func usageLine(_ name: String, _ usage: ProviderUsage) -> String {
        if let error = usage.error, usage.primary.percent == nil, usage.weekly.percent == nil {
            return "\(name)：\(error)"
        }
        let primary = window("5h", usage.primary)
        let weekly = window("周", usage.weekly)
        return "\(name)　\(primary)　\(weekly)"
    }
    private static func window(_ label: String, _ usage: UsageWindow) -> String {
        guard let percent = usage.percent else { return "\(label) —" }
        let reset = usage.resetMinutes.map { " · \(formatMinutes($0))" } ?? ""
        return "\(label) \(Int(percent))%\(reset)"
    }
    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 24 * 60 {
            return "\(minutes / (24 * 60))d \(minutes % (24 * 60) / 60)h"
        }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(0, minutes))m"
    }
    private func refreshDevice() {
        guard !DeviceClient.host.isEmpty else { device.title = "屏幕：未设置"; return }
        device.title = "屏幕：连接中…"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(info):
                let state = info.stale ? "数据陈旧" : "在线"
                let mode = ["dashboard": "双栏", "claude": "Claude", "codex": "Codex"][info.mode] ?? info.mode
                let age = info.lastFetchAge.map { " · \(PreviewPopoverController.formatAge($0))前更新" } ?? ""
                self.device.title = "屏幕：\(state) · \(mode)\(age)"
                self.modeItems.forEach { $0.value.state = $0.key == info.mode ? .on : .off }
            case .failure:
                self.device.title = "屏幕：无法连接 \(DeviceClient.host)"
                self.modeItems.values.forEach { $0.state = .off }
                let seen = DeviceClient.lastSeenIP
                if !seen.isEmpty, !DeviceClient.host.contains(seen) {
                    DeviceClient.verify("\(seen):8766") { valid in
                        if valid { DeviceClient.host = "\(seen):8766"; self.refreshDevice() }
                    }
                }
            }
        }
    }

    @objc private func pair() {
        device.title = "屏幕：查找中…"
        DeviceClient.autoPair(progress: { [weak self] in self?.device.title = "屏幕：\($0)" }) { [weak self] found in
            Self.alert(found == nil ? "未找到屏幕" : "配对成功", found ?? "请确认树莓派与 Mac 在同一局域网，或手动设置地址。")
            self?.refreshDevice()
        }
    }
    @objc private func setAddress() {
        let alert = NSAlert(); alert.messageText = "树莓派屏幕地址"
        alert.informativeText = "例如 192.168.1.50:8766"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = DeviceClient.host; alert.accessoryView = input
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceClient.host = DeviceClient.normalizedHost(input.stringValue)
            refreshDevice()
        }
    }
    @objc private func openDeviceStatus() {
        guard let base = DeviceClient.baseURL else { setAddress(); return }
        NSWorkspace.shared.open(base.appendingPathComponent("v1/device"))
    }
    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DeviceClient.setMode(mode) { [weak self] error in self?.finish(error); self?.refreshDevice() }
    }
    @objc private func smartRefresh() {
        DeviceClient.refresh("smart") { [weak self] error in self?.finish(error) }
    }
    @objc private func fullRefresh() {
        DeviceClient.refresh("full") { [weak self] error in self?.finish(error) }
    }
    @objc private func pointHere() {
        guard let ip = DeviceClient.localIPv4() else { Self.alert("设置失败", "无法取得本机局域网地址"); return }
        let url = "http://\(ip):\(port)"
        DeviceClient.setBridge(url) { [weak self] error in
            self?.finish(error)
            if error == nil { Self.alert("桥接已设置", "设备将从 \(url)/v1/status 拉取数据。") }
        }
    }
    @objc private func showBridgeAddress() {
        let ip = DeviceClient.localIPv4() ?? "<本机局域网 IP>"
        Self.alert("桥接服务地址", "http://\(ip):\(port)/v1/status\n\n设备地址：\(DeviceClient.host.isEmpty ? "未设置" : DeviceClient.host)")
    }
    private func finish(_ error: Error?) { if let error { Self.alert("操作失败", error.localizedDescription) } }
    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: selector, keyEquivalent: key); value.target = self; return value
    }
    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
