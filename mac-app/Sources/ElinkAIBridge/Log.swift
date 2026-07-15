import Foundation

enum Log {
    enum Level: String, CaseIterable {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    private static let queue = DispatchQueue(label: "elink.log")
    private static let maximumSize = 2_000_000
    private static var isPrepared = false
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return value
    }()

    static func info(_ message: String, category: String = "app") {
        write(level: .info, category: category, message: message)
    }

    static func warning(_ message: String, category: String = "app") {
        write(level: .warning, category: category, message: message)
    }

    static func error(_ message: String, category: String = "app") {
        write(level: .error, category: category, message: message)
    }

    static func user(_ message: String, level: Level = .info) {
        write(level: level, category: "user", message: message)
    }

    static func device(_ message: String, level: Level = .info) {
        write(level: level, category: "device", message: message)
    }

    /// Ensures that Settings always has a real, persistent file to open and
    /// waits for all log entries queued before this call to reach disk.
    static func fileURL() -> URL {
        queue.sync { prepareIfNeeded() }
        return AppInfo.logURL
    }

    static func flush() {
        queue.sync { prepareIfNeeded() }
    }

    static func redacted(_ message: String) -> String {
        let replacements = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1<redacted>"),
            (#"(?i)((?:access|refresh)[_-]?token|api[_-]?key|authorization)(\s*[\"']?\s*[:=]\s*[\"']?)[^\"'\s,}]+"#, "$1$2<redacted>"),
        ]
        return replacements.reduce(message) { value, replacement in
            value.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    static func formattedLine(level: Level, category: String, message: String,
                              at date: Date = Date()) -> String {
        "\(formatter.string(from: date)) [\(level.rawValue)] [\(category)] \(redacted(message))\n"
    }

    private static func write(level: Level, category: String, message: String) {
        queue.async {
            prepareIfNeeded()
            let line = formattedLine(level: level, category: category, message: message)
            rotateIfNeeded(adding: line.utf8.count)
            append(Data(line.utf8))
        }
    }

    private static func prepareIfNeeded() {
        guard !isPrepared else { return }
        do {
            try FileManager.default.createDirectory(
                at: AppInfo.logDirectoryURL,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: AppInfo.logPath) {
                migrateLegacyLogIfPresent()
            }
            if !FileManager.default.fileExists(atPath: AppInfo.logPath) {
                FileManager.default.createFile(atPath: AppInfo.logPath, contents: nil)
            }
            rotateIfNeeded(adding: 0)
            isPrepared = true
        } catch {
            FileHandle.standardError.write(Data("[log] \(error.localizedDescription)\n".utf8))
        }
    }

    private static func migrateLegacyLogIfPresent() {
        guard let data = FileManager.default.contents(atPath: AppInfo.legacyLogPath),
              !data.isEmpty else { return }
        try? data.write(to: AppInfo.logURL, options: .atomic)
    }

    private static func rotateIfNeeded(adding bytes: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: AppInfo.logPath)[.size]) as? Int ?? 0
        guard size + bytes > maximumSize else { return }
        try? FileManager.default.removeItem(at: AppInfo.archivedLogURL)
        try? FileManager.default.moveItem(at: AppInfo.logURL, to: AppInfo.archivedLogURL)
        FileManager.default.createFile(atPath: AppInfo.logPath, contents: nil)
    }

    private static func append(_ data: Data) {
        guard let handle = FileHandle(forWritingAtPath: AppInfo.logPath) else {
            FileManager.default.createFile(atPath: AppInfo.logPath, contents: data)
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("[log] \(error.localizedDescription)\n".utf8))
        }
    }
}
