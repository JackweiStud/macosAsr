import Foundation

/// Append-only logger to `<repo>/log/macapp.log` (SDD §11, docs/dev/LOGGING.md).
enum AppLogger {
    private static let queue = DispatchQueue(label: "com.macosasr.applogger")

    /// 默认 INFO；DEBUG 仅 verbose 排查时写入文件。
    static func log(_ message: String, level: String = "INFO") {
        if level == "DEBUG" { return }
        queue.sync {
            let line = "\(isoTimestamp()) \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = ProjectPaths.logFile
            ensureLogDirectory(url)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func ensureLogDirectory(_ logFile: URL) {
        let dir = logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
