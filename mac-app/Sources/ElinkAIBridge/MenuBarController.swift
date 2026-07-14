import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let preview: PreviewPopoverController
    private let usage: UsageFetcher
    private let claude = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codex = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let device = NSMenuItem(title: "屏幕：未设置", action: nil, keyEquivalent: "")

    init(usage: UsageFetcher, status: StatusService, port: UInt16) {
        self.usage = usage
        self.preview = PreviewPopoverController(status: status, usage: usage, port: port)
        super.init(); build()
        if let button = item.button {
            button.image = Self.menuBarImage(percent: nil)
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        usage.onUpdate = { [weak self] in self?.refreshUsage() }
    }

    private static let menuBarSourceImage = AppLogo.image

    private static func menuBarImage(percent: Double?) -> NSImage? {
        let fallback = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Elink AI"
        )
        guard let source = menuBarSourceImage else {
            return fallback
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .high

            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 3.6, yRadius: 3.6)
            shape.addClip()
            if let percent {
                Self.statusColor(percent: percent).setFill()
                rect.fill()
                source.draw(in: rect, from: .zero, operation: .multiply, fraction: 1)
            } else {
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        image.accessibilityDescription = "Elink AI"
        return image
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
        menu.addItem(.separator()); menu.addItem(action("刷新全部状态", #selector(refreshAll), key: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) { refreshAll() }

    @objc private func refreshAll() { usage.refresh(); refreshUsage(); refreshDevice() }
    private func refreshUsage() {
        claude.title = Self.usageLine("Claude", usage.claude)
        codex.title = Self.usageLine("Codex", usage.codex)
        refreshStatusButton()
    }
    private func refreshStatusButton() {
        guard let button = item.button else { return }
        if let percent = usage.claude.primary.percent {
            button.image = Self.menuBarImage(percent: percent)
            button.imagePosition = .imageLeft
            button.attributedTitle = Self.statusTitle(percent: percent)
        } else {
            button.image = Self.menuBarImage(percent: nil)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
        }
    }
    static func statusColor(percent: Double) -> NSColor {
        switch UsageLevel.level(usedPercent: percent) {
        case .healthy: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
    static func statusTitle(percent: Double) -> NSAttributedString {
        return NSAttributedString(string: "\(Int(percent))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: statusColor(percent: percent),
        ])
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
        let reset = " · \(usage.resetMinutes.map(formatMinutes) ?? "—")"
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
            case .failure:
                self.device.title = "屏幕：无法连接 \(DeviceClient.host)"
                let seen = DeviceClient.lastSeenIP
                if !seen.isEmpty, !DeviceClient.host.contains(seen) {
                    DeviceClient.verify("\(seen):8766") { valid in
                        if valid { DeviceClient.host = "\(seen):8766"; self.refreshDevice() }
                    }
                }
            }
        }
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: selector, keyEquivalent: key); value.target = self; return value
    }
}
