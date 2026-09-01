import Foundation

/// Shared contract between the meeting capture/orchestration side and the
/// diarization+ASR processor: one speaker-attributed utterance.
struct MeetingUtterance: Sendable {
    let speakerLabel: String   // "SPEAKER_00", …
    let tStartMs: Int64
    let tEndMs: Int64
    let text: String
    let confidence: Double?
}
