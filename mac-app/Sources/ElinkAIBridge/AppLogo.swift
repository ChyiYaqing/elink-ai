import AppKit

enum AppLogo {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "ElinkAIBridge", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "elink-ai-menubar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }()
}
