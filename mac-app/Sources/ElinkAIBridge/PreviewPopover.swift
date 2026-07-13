import AppKit

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let imageView = NSImageView()
    private let modeControl = NSSegmentedControl(
        labels: ["双栏", "Claude", "Codex"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let smartButton = NSButton(title: "智能刷新", target: nil, action: nil)
    private let fullButton = NSButton(title: "完整刷新", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "正在载入设备预览…")
    private var pollTimer: Timer?
    private var loadingPreview = false
    private var actionInFlight = false

    override init() {
        super.init()
        let controller = NSViewController()
        controller.preferredContentSize = NSSize(width: 560, height: 476)
        let container = NSView(frame: NSRect(origin: .zero, size: controller.preferredContentSize))

        imageView.frame = NSRect(x: 10, y: 66, width: 540, height: 400)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .grayBezel
        imageView.setAccessibilityLabel("电子纸最后送屏画面")

        modeControl.frame = NSRect(x: 10, y: 35, width: 260, height: 24)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        modeControl.toolTip = "切换电子纸页面"

        smartButton.frame = NSRect(x: 280, y: 34, width: 125, height: 26)
        smartButton.bezelStyle = .rounded
        smartButton.target = self
        smartButton.action = #selector(smartRefresh)
        smartButton.toolTip = "仅在内容变化时送屏，并自动选择刷新方式"

        fullButton.frame = NSRect(x: 415, y: 34, width: 135, height: 26)
        fullButton.bezelStyle = .rounded
        fullButton.target = self
        fullButton.action = #selector(fullRefresh)
        fullButton.toolTip = "完整刷新电子纸，用于清除残影"

        label.frame = NSRect(x: 12, y: 8, width: 536, height: 18)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle

        [imageView, modeControl, smartButton, fullButton, label].forEach(container.addSubview)
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startPolling()
        reload()
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        reloadInfo()
        guard !loadingPreview else { return }
        loadingPreview = true
        DeviceClient.fetchPreview { [weak self] result in
            guard let self else { return }
            self.loadingPreview = false
            switch result {
            case let .success(data):
                if let image = NSImage(data: data) { self.imageView.image = image }
            case let .failure(error):
                if !self.actionInFlight { self.label.stringValue = error.localizedDescription }
            }
        }
    }

    private func reloadInfo() {
        DeviceClient.fetchInfo { [weak self] result in
            guard let self, !self.actionInFlight else { return }
            switch result {
            case let .success(info):
                self.modeControl.selectedSegment = Self.segment(for: info.mode)
                self.label.stringValue = Self.deviceSummary(info)
            case let .failure(error):
                self.label.stringValue = "设备离线 · \(error.localizedDescription)"
            }
        }
    }

    @objc private func modeChanged() {
        let modes = ["dashboard", "claude", "codex"]
        guard modeControl.selectedSegment >= 0,
              modeControl.selectedSegment < modes.count else { return }
        performAction("正在切换页面…") { completion in
            DeviceClient.setMode(modes[self.modeControl.selectedSegment], completion: completion)
        }
    }

    @objc private func smartRefresh() {
        performAction("正在请求智能刷新…") { DeviceClient.refresh("smart", completion: $0) }
    }

    @objc private func fullRefresh() {
        performAction("正在请求完整刷新…") { DeviceClient.refresh("full", completion: $0) }
    }

    private func performAction(_ progress: String,
                               action: (@escaping (Error?) -> Void) -> Void) {
        guard !actionInFlight else { return }
        actionInFlight = true
        setControlsEnabled(false)
        label.stringValue = progress
        action { [weak self] error in
            guard let self else { return }
            self.actionInFlight = false
            self.setControlsEnabled(true)
            if let error {
                self.label.stringValue = "操作失败 · \(error.localizedDescription)"
            } else {
                self.label.stringValue = "请求已发送，等待设备完成送屏…"
                self.reload()
            }
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        modeControl.isEnabled = enabled
        smartButton.isEnabled = enabled
        fullButton.isEnabled = enabled
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
