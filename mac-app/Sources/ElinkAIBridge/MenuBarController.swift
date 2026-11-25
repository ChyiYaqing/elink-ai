import AppKit

final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let preview: PreviewPopoverController
    private let usage: UsageFetcher
    private let status: StatusService

    init(usage: UsageFetcher, status: StatusService, cluster: ClusterManager,
         link: LinkMonitor, mesh: MeshMonitor, kiwi: KiwiVMMonitor, port: UInt16) {
        self.usage = usage
        self.status = status
        self.preview = PreviewPopoverController(status: status, usage: usage, cluster: cluster,
                                                link: link, mesh: mesh, kiwi: kiwi, port: port)
        super.init()
        if let button = item.button {
            button.image = Self.menuBarImage(percent: nil)
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp])
        }
        usage.onUpdate = { [weak self] in self?.refreshUsage() }
        refreshStatusButton()
    }

    // Menubar 只能使用专用资源；AppLogo.image 的系统应用图标回退在裸可执行文件下
    // 会变成 Finder/文件夹样式。
    private static let menuBarSourceImage = AppLogo.menuBarImage

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
        preview.toggle(relativeTo: button)
    }

    private func refreshUsage() {
        refreshStatusButton()
    }
    private func refreshStatusButton() {
        // 与面板一致：用集群聚合后的快照，本机被限流时仍能取到
        // 其他节点同步来的最新配额。snapshot() 读文件，放到后台线程。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.status.snapshot()
            let percent = Self.menuBarWeeklyPercent(
                claudeWeekly: snapshot.claude.weekly.percent,
                codexWeekly: snapshot.codex.weekly.percent,
                geminiWeekly: snapshot.gemini.weekly.percent
            )
            DispatchQueue.main.async {
                guard let button = self.item.button else { return }
                button.image = Self.menuBarImage(percent: percent)
                if let percent {
                    button.imagePosition = .imageLeft
                    button.attributedTitle = Self.statusTitle(percent: percent)
                } else {
                    button.imagePosition = .imageOnly
                    button.attributedTitle = NSAttributedString()
                }
            }
        }
    }
    static func menuBarWeeklyPercent(claudeWeekly: Double?, codexWeekly: Double?,
                                     geminiWeekly: Double? = nil) -> Double? {
        [claudeWeekly, codexWeekly, geminiWeekly].compactMap { $0 }.max()
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
}
