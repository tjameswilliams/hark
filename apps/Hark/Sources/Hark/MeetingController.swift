import Foundation

/// User-visible meeting-recording state, mirrored into the status menu.
enum MeetingState: Equatable {
    case idle
    case recording(startedAt: Date)
}

/// Orchestrates meeting recording: start/stop the tap+mic capture, then hand
/// the finished WAV to the processor (diarization + ASR) and persist the
/// utterances into the Rust core's SQLite store. Processing is fail-open —
/// the recording file is never lost, whatever happens downstream.
@MainActor
final class MeetingController {
    private let capture = MeetingCapture()
    /// The store is owned by the pipeline and opened during pipeline.start();
    /// resolve it lazily so construction order doesn't matter.
    private let storeProvider: () -> HarkStore?
    /// ISO8601DateFormatter defaults to UTC with a Z suffix (same convention
    /// as DictationPipeline's persisted timestamps).
    private let isoFormatter = ISO8601DateFormatter()

    /// Fires on every state change; the status item mirrors it into the menu.
    var onStateChange: ((MeetingState) -> Void)?
    /// Fires after a meeting transcript is persisted (kicks background indexing).
    var onMeetingStored: (() -> Void)?
    private(set) var state: MeetingState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Number of stopped recordings still being diarized/transcribed. The menu
    /// shows "Processing meeting…" while this is nonzero — without it, the
    /// window between Stop and the meeting appearing looks like nothing
    /// happened (observed in the field).
    private(set) var processingCount = 0 {
        didSet { onStateChange?(state) }
    }
    var isProcessing: Bool { processingCount > 0 }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    init(storeProvider: @escaping () -> HarkStore?) {
        self.storeProvider = storeProvider
        // An audio-server restart mid-meeting kills the tap; MeetingCapture
        // finalizes the partial WAV and hands it here — process it exactly
        // like a normal stop so nothing recorded is ever lost.
        capture.onCaptureLost = { [weak self] url, startedAt, endedAt, micPeak, systemPeak in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = .idle
                    harkLog(String(
                        format: "meeting: capture lost — peaks mic %.4f, system %.4f. processing partial %@ …",
                        micPeak, systemPeak, url.lastPathComponent))
                    self.processRecording(url: url, startedAt: startedAt, endedAt: endedAt)
                }
            }
        }
    }

    // MARK: - Recording

    /// Starts capturing. Uses the same pinned-input-device preference as
    /// dictation ("inputDeviceUID" in UserDefaults), falling back to the
    /// system default input.
    func startRecording() {
        guard !isRecording else { return }
        let pinnedUID = UserDefaults.standard.string(forKey: "inputDeviceUID")
        do {
            try capture.start(micDeviceUID: pinnedUID)
            state = .recording(startedAt: Date())
        } catch {
            harkLog("meeting: could not start recording: \(error)")
        }
    }

    /// Stops capturing and kicks off processing + persistence in the
    /// background. The menu returns to idle immediately.
    func stopRecording() {
        guard isRecording, capture.isRecording else { return }
        let result = capture.stop()
        state = .idle

        harkLog(String(
            format: "meeting: peaks — mic %.4f, system %.4f. processing %@ …",
            result.micPeak, result.systemPeak, result.url.lastPathComponent))

        processRecording(url: result.url, startedAt: result.startedAt, endedAt: result.endedAt)
    }

    /// Shared post-capture path (normal stop AND capture-lost recovery):
    /// diarize + transcribe in the background, then persist.
    private func processRecording(url: URL, startedAt: Date, endedAt: Date) {
        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "Meeting \(titleFormatter.string(from: startedAt))"
        let startedAtISO = isoFormatter.string(from: startedAt)
        let endedAtISO = isoFormatter.string(from: endedAt)

        processingCount += 1
        Task { @MainActor in
            defer { self.processingCount -= 1 }
            do {
                let utterances = try await MeetingProcessor.process(
                    fileURL: url,
                    progress: { line in harkLog("meeting: \(line)") })
                self.persist(
                    title: title, startedAt: startedAtISO, endedAt: endedAtISO,
                    audioPath: url.path, utterances: utterances)
            } catch {
                harkLog("meeting: processing FAILED (\(error)) — recording kept at \(url.path)")
            }
        }
    }

    /// Best-effort cleanup on app exit (closes the WAV so the recording on
    /// disk stays valid even mid-meeting).
    func teardown() {
        if isRecording {
            harkLog("meeting: app quitting mid-recording — finalizing the file.")
            stopRecording()
        }
    }

    // MARK: - Persistence

    private func persist(
        title: String, startedAt: String, endedAt: String,
        audioPath: String, utterances: [MeetingUtterance]
    ) {
        guard let store = storeProvider() else {
            harkLog("meeting: store unavailable — transcript not persisted; recording kept at \(audioPath)")
            return
        }
        let segments = utterances.map {
            MeetingSegmentInput(
                speakerLabel: $0.speakerLabel,
                tStartMs: $0.tStartMs,
                tEndMs: $0.tEndMs,
                text: $0.text,
                confidence: $0.confidence)
        }
        do {
            let id = try store.recordMeeting(
                title: title,
                startedAt: startedAt,
                endedAt: endedAt,
                audioPath: audioPath,
                segments: segments)
            harkLog("meeting: #\(id) stored (\(segments.count) segment(s)).")
            onMeetingStored?()
        } catch {
            harkLog("meeting: WARNING — failed to store the transcript (\(error)); recording kept at \(audioPath)")
        }
    }

    // MARK: - Menu queries

    /// Last `limit` meetings, newest first; empty on any store problem.
    func recentMeetings(limit: UInt32) -> [MeetingRecord] {
        guard let store = storeProvider() else { return [] }
        do {
            return try store.recentMeetings(limit: limit)
        } catch {
            harkLog("meeting: WARNING — could not read recent meetings: \(error)")
            return []
        }
    }

    /// Speaker-attributed transcript for one meeting, nil on failure.
    func transcript(id: Int64) -> String? {
        guard let store = storeProvider() else { return nil }
        do {
            return try store.meetingTranscript(id: id)
        } catch {
            harkLog("meeting: WARNING — could not read the transcript for meeting #\(id): \(error)")
            return nil
        }
    }
}
