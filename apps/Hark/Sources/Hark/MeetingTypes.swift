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

/// What the diarizer learned about one speaker label, kept so the voice can
/// be named after the meeting and recognized in later ones.
struct MeetingSpeakerProfile: Sendable {
    let label: String          // matches MeetingUtterance.speakerLabel
    /// L2-normalized speaker embedding averaged over the label's speech.
    let voiceprint: [Float]
    let talkMs: Int64
    /// Share (0…1) of the label's audio energy that arrived on the mic
    /// channel: near 1 for the person at this Mac, near 0 for remote voices.
    /// 0 when the recording has no separate mic channel.
    let micShare: Double
    /// The stretch that best represents this voice, for "who is this?".
    let clipStartMs: Int64
    let clipEndMs: Int64
}

struct MeetingProcessingResult: Sendable {
    let utterances: [MeetingUtterance]
    let speakers: [MeetingSpeakerProfile]
}
