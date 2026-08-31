import Foundation

enum TraceLog {
    private static let maxLogBytes = 1_048_576
    private static let trimmedLogBytes = 786_432

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func append(_ message: String, filename: String) {
        appendLine("[\(formatter.string(from: Date()))] \(message)", filename: filename)
    }

    static func appendRawLine(_ line: String, filename: String) {
        appendLine(line, filename: filename)
    }

    private static func appendLine(_ line: String, filename: String) {
        let support = supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        let url = support.appendingPathComponent(filename)
        guard let data = "\(line)\n".data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: [.atomic])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        trimIfNeeded(url)
    }

    static func url(for filename: String) -> URL {
        supportDirectory.appendingPathComponent(filename)
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RatRemote", isDirectory: true)
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxLogBytes,
              let data = try? Data(contentsOf: url) else {
            return
        }
        let suffix = data.suffix(trimmedLogBytes)
        try? Data(suffix).write(to: url, options: [.atomic])
    }
}
