import AppKit

final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let imageView = NSImageView(frame: NSRect(x: 0, y: 28, width: 540, height: 400))
    private let label = NSTextField(labelWithString: "正在载入设备预览…")

    override init() {
        super.init()
        let controller = NSViewController()
        controller.preferredContentSize = NSSize(width: 540, height: 428)
        controller.view = NSView(frame: NSRect(origin: .zero, size: controller.preferredContentSize))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: 12, y: 4, width: 516, height: 20)
        label.alignment = .center
        controller.view.addSubview(imageView); controller.view.addSubview(label)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        reload()
    }

    private func reload() {
        label.stringValue = "正在载入设备预览…"
        DeviceClient.fetchPreview { [weak self] result in
            switch result {
            case let .success(data):
                self?.imageView.image = NSImage(data: data)
                self?.label.stringValue = "与设备最后一次送屏画面一致"
            case let .failure(error):
                self?.label.stringValue = error.localizedDescription
            }
        }
    }
}
