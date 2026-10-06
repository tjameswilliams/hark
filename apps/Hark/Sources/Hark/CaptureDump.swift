import Foundation

/// Debug aid: keeps a copy of each dictation's capture (16 kHz mono, exactly
/// what the transcriber saw) under ~/Library/Application Support/Hark/captures
/// so a failing dictation can be replayed through the model outside Hark.
/// Off unless the "dumpCaptures" default is on (General settings). Only the
/// newest `keep` files are retained.
enum CaptureDump {
    static let defaultsKey = "dumpCaptures"
    static let keep = 20

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hark", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
    }

    /// Writes `samples` as 16-bit PCM and prunes older dumps. Returns the file
    /// URL, or nil (after logging) when anything went wrong — a dump failure
    /// must never affect the dictation itself.
    static func write(_ samples: [Float], capturedAt: Date) -> URL? {
        let dir = directory
        let stamp = ISO8601DateFormatter().string(from: capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp).wav")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let writer = try WavStreamWriter(
                url: url, channels: 1, sampleRate: Int(AudioSpec.sampleRate))
            writer.append(samples.map { Int16(max(-1, min(1, $0)) * 32767) })
            writer.finish()
        } catch {
            harkLog("capture dump: WARNING — could not write \(url.lastPathComponent): \(error)")
            return nil
        }
        prune(dir)
        return url
    }

    private static func prune(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return }
        let wavs = files.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }  // ISO stamps sort by time
        for stale in wavs.dropLast(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
