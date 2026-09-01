import AVFoundation
import Foundation

// In the app this type is defined elsewhere; the spike keeps a copy here (NOT
// in MeetingProcessor.swift) so the drop-in causes no duplicate definitions.
struct MeetingUtterance: Sendable {
    let speakerLabel: String  // "SPEAKER_00", …
    let tStartMs: Int64
    let tEndMs: Int64
    let text: String
    let confidence: Double?
}

func formatTimestamp(_ ms: Int64) -> String {
    let totalSeconds = ms / 1000
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: meetingproc <meeting.wav>")
    exit(64)
}
let fileURL = URL(fileURLWithPath: arguments[1])

// Audio duration for RTFx reporting.
let audioSeconds: Double
do {
    let file = try AVAudioFile(forReading: fileURL)
    audioSeconds = Double(file.length) / file.processingFormat.sampleRate
} catch {
    FileHandle.standardError.write(Data("cannot read \(fileURL.path): \(error)\n".utf8))
    exit(66)
}

let start = ContinuousClock.now
do {
    let utterances = try await MeetingProcessor.process(fileURL: fileURL) { stage in
        FileHandle.standardError.write(Data("[progress] \(stage)\n".utf8))
    }
    let elapsed = ContinuousClock.now - start
    let elapsedSeconds =
        Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18

    print("")
    for utterance in utterances {
        let confidenceText = utterance.confidence.map { String(format: " (conf %.2f)", $0) } ?? ""
        print(
            "[\(formatTimestamp(utterance.tStartMs))] \(utterance.speakerLabel): \(utterance.text)\(confidenceText)"
        )
    }
    let speakers = Set(utterances.map(\.speakerLabel))
    print("")
    print(String(format: "audio: %.1f s   processing: %.1f s   RTFx: %.1fx", audioSeconds, elapsedSeconds, audioSeconds / max(elapsedSeconds, 1e-9)))
    print("speakers detected: \(speakers.count) \(speakers.sorted())")
    print("utterances: \(utterances.count)")
} catch {
    FileHandle.standardError.write(Data("processing failed: \(error)\n".utf8))
    exit(1)
}
