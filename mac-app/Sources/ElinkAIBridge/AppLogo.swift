import AppKit

enum AppLogo {
    static let menuBarImage: NSImage? = {
        let bundled = Bundle.main.url(forResource: "elink-ai-menubar", withExtension: "png")
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/elink-ai-menubar.png")
            .standardizedFileURL
        return [bundled, sourceTree].compactMap { $0 }.lazy
            .compactMap(NSImage.init(contentsOf:))
            .first
    }()

    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "ElinkAIBridge", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let menuBarImage { return menuBarImage }
        return NSApp.applicationIconImage
    }()
}
