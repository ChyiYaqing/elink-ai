import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "elink.log")
    // 首次写入前检查：超过 2MB 直接清空，避免 /tmp 日志无限增长
    private static let prepared: Bool = {
        let size = (try? FileManager.default.attributesOfItem(atPath: AppInfo.logPath))?[.size] as? Int
        if let size, size > 2_000_000 {
            try? FileManager.default.removeItem(atPath: AppInfo.logPath)
        }
        return true
    }()
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return value
    }()

    static func info(_ message: String) {
        _ = prepared
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: AppInfo.logPath) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                FileManager.default.createFile(atPath: AppInfo.logPath, contents: Data(line.utf8))
            }
        }
    }
}
