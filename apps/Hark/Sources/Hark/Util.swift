import Foundation
import os

/// Unified logger: Console.app-visible when Hark runs as an app bundle.
let harkOSLog = Logger(subsystem: "com.hark.app", category: "pipeline")

/// Append-only file log at ~/Library/Logs/Hark/hark.log — the reliable record
/// when the app is launched via Finder/`open` (stdout lost) and unified-log
/// info entries aren't persisted for `log show`. Lock-serialized: harkLog is
/// called from the main actor and from async pipeline tasks.
private final class HarkFileLog: @unchecked Sendable {
    static let shared = HarkFileLog()
    private let lock = NSLock()
    private let handle: FileHandle?

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hark", isDirectory: true)
        let url = dir.appendingPathComponent("hark.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ message: String) {
        guard let handle else { return }
        let line = "\(Date().ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true))) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        lock.withLock {
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Logs pipeline events to stdout (shell runs), the unified logging system
/// (Console.app), and ~/Library/Logs/Hark/hark.log (always).
func harkLog(_ message: String) {
    print("[hark] \(message)")
    harkOSLog.notice("\(message, privacy: .public)")
    HarkFileLog.shared.write(message)
}

extension Duration {
    /// Total seconds as a Double.
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Total milliseconds as a Double.
    var millisecondsValue: Double {
        secondsValue * 1000
    }
}
