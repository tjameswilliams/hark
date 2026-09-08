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
///
/// Every stop, whatever its cause, produces a MeetingReviewSession that the
/// review window shows: processing progress first, then the name-and-file
/// form. A silence monitor ends recordings the user forgot about.
@MainActor
final class MeetingController: MeetingFiler {
    private let capture = MeetingCapture()
    /// The store is owned by the pipeline and opened during pipeline.start();
    /// resolve it lazily so construction order doesn't matter.
    private let storeProvider: () -> HarkStore?
    /// ISO8601DateFormatter defaults to UTC with a Z suffix (same convention
    /// as DictationPipeline's persisted timestamps).
    private let isoFormatter = ISO8601DateFormatter()

    /// Fires on every state change; the status item mirrors it into the menu.
    var onStateChange: ((MeetingState) -> Void)?
    /// Fires after a meeting transcript is persisted, and again after it is
    /// filed (kicks background indexing).
    var onMeetingStored: (() -> Void)?
    /// Fires the moment a recording stops, with the session the review
    /// window should show. Processing continues in the background and
    /// updates the session's phase.
    var onMeetingFinished: ((MeetingReviewSession) -> Void)?

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

    // MARK: - Silence monitor

    /// UserDefaults key: minutes of silence after which a recording stops on
    /// its own. 0 disables. Missing means the default below.
    static let silenceMinutesKey = "meetingSilenceMinutes"
    static let defaultSilenceMinutes = 2
    /// A recording that never carried any sound (the call never connected,
    /// wrong input device) is stopped after this long regardless, so a
    /// forgotten empty recording cannot run for hours.
    private static let neverActiveStopSeconds: TimeInterval = 10 * 60
    private static let silenceCheckInterval: TimeInterval = 5
    private var silenceTimer: Timer?

    /// Effective silence window in seconds; 0 when the feature is off.
    var silenceStopSeconds: TimeInterval {
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: Self.silenceMinutesKey) == nil
            ? Self.defaultSilenceMinutes
            : defaults.integer(forKey: Self.silenceMinutesKey)
        return minutes > 0 ? TimeInterval(minutes * 60) : 0
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
                    self.stopSilenceMonitor()
                    harkLog(String(
                        format: "meeting: capture lost — peaks mic %.4f, system %.4f. processing partial %@ …",
                        micPeak, systemPeak, url.lastPathComponent))
                    self.processRecording(url: url, startedAt: startedAt, endedAt: endedAt, reason: .captureLost)
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
            startSilenceMonitor()
        } catch {
            harkLog("meeting: could not start recording: \(error)")
        }
    }

    /// Stops capturing and kicks off processing + persistence in the
    /// background. The menu returns to idle immediately; the review window
    /// opens with the processing view.
    func stopRecording(reason: MeetingStopReason = .user) {
        guard isRecording, capture.isRecording else { return }
        stopSilenceMonitor()
        let result = capture.stop()
        state = .idle

        harkLog(String(
            format: "meeting: peaks — mic %.4f, system %.4f. processing %@ …",
            result.micPeak, result.systemPeak, result.url.lastPathComponent))

        processRecording(url: result.url, startedAt: result.startedAt, endedAt: result.endedAt, reason: reason)
    }

    private func startSilenceMonitor() {
        stopSilenceMonitor()
        // Target/selector, not the block API — the @Sendable block would
        // need to capture this non-Sendable MainActor object. .common mode so
        // it keeps ticking while the status menu is open.
        let timer = Timer(
            timeInterval: Self.silenceCheckInterval, target: self,
            selector: #selector(silenceTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceMonitor() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    @objc private func silenceTick() {
        guard isRecording, let startedAt = capture.recordingStartedAt else { return }
        let window = silenceStopSeconds
        guard window > 0 else { return }
        let now = Date()
        if let last = capture.lastActivityAt {
            let quiet = now.timeIntervalSince(last)
            if quiet >= window {
                harkLog(String(format: "meeting: %.0f s of silence — stopping automatically.", quiet))
                stopRecording(reason: .silence(seconds: Int(window)))
            }
        } else if now.timeIntervalSince(startedAt) >= max(window, Self.neverActiveStopSeconds) {
            harkLog("meeting: no sound at all since the recording started — stopping automatically.")
            stopRecording(reason: .silence(seconds: Int(now.timeIntervalSince(startedAt))))
        }
    }

    /// Shared post-capture path (normal stop, silence stop, AND capture-lost
    /// recovery): announce the review session, then diarize + transcribe in
    /// the background and persist.
    private func processRecording(url: URL, startedAt: Date, endedAt: Date, reason: MeetingStopReason) {
        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "Meeting \(titleFormatter.string(from: startedAt))"
        let startedAtISO = isoFormatter.string(from: startedAt)
        let endedAtISO = isoFormatter.string(from: endedAt)

        let session = MeetingReviewSession(
            startedAt: startedAt, endedAt: endedAt, stopReason: reason,
            audioPath: url.path, defaultTitle: title)
        onMeetingFinished?(session)

        processingCount += 1
        Task { @MainActor in
            defer { self.processingCount -= 1 }
            do {
                let utterances = try await MeetingProcessor.process(
                    fileURL: url,
                    progress: { line in
                        harkLog("meeting: \(line)")
                        Task { @MainActor in
                            if case .processing = session.phase {
                                session.phase = .processing(stage: line)
                            }
                        }
                    })
                session.phase = .processing(stage: "saving…")
                if let id = self.persist(
                    title: title, startedAt: startedAtISO, endedAt: endedAtISO,
                    audioPath: url.path, utterances: utterances) {
                    session.speakerCount = Set(utterances.map(\.speakerLabel)).count
                    session.segmentCount = utterances.count
                    session.transcript = self.transcript(id: id) ?? ""
                    session.phase = .ready(sessionId: id)
                } else {
                    session.phase = .failed("The transcript could not be saved to the database.")
                }
            } catch {
                harkLog("meeting: processing FAILED (\(error)) — recording kept at \(url.path)")
                session.phase = .failed("\(error)")
            }
        }
    }

    /// Best-effort cleanup on app exit (closes the WAV so the recording on
    /// disk stays valid even mid-meeting).
    func teardown() {
        if isRecording {
            harkLog("meeting: app quitting mid-recording — finalizing the file.")
            stopRecording(reason: .quit)
        }
    }

    // MARK: - Persistence

    /// Returns the new session id, or nil (logged) when the store is
    /// unavailable or the insert fails.
    private func persist(
        title: String, startedAt: String, endedAt: String,
        audioPath: String, utterances: [MeetingUtterance]
    ) -> Int64? {
        guard let store = storeProvider() else {
            harkLog("meeting: store unavailable — transcript not persisted; recording kept at \(audioPath)")
            return nil
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
            return id
        } catch {
            harkLog("meeting: WARNING — failed to store the transcript (\(error)); recording kept at \(audioPath)")
            return nil
        }
    }

    // MARK: - MeetingFiler

    func projectChoices() -> [(id: Int64, name: String)] {
        guard let store = storeProvider() else { return [] }
        do {
            return try store.listProjects().map { (id: $0.id, name: $0.name) }
        } catch {
            harkLog("meeting review: WARNING — could not list projects: \(error)")
            return []
        }
    }

    func file(_ session: MeetingReviewSession, title: String, projectId: Int64?, newProjectName: String?) throws {
        guard case .ready(let sessionId) = session.phase else {
            throw MeetingFilingError.notReady
        }
        guard let store = storeProvider() else { throw MeetingFilingError.storeUnavailable }

        var targetProject = projectId
        var projectName: String?
        if let newProjectName, !newProjectName.isEmpty {
            targetProject = try store.createProject(name: newProjectName, description: nil)
            projectName = newProjectName
        } else if let projectId {
            projectName = projectChoices().first(where: { $0.id == projectId })?.name
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.renameSession(sessionId: sessionId, title: trimmed.isEmpty ? nil : trimmed)
        try store.assignSession(sessionId: sessionId, projectId: targetProject)

        session.title = trimmed.isEmpty ? session.defaultTitle : trimmed
        session.phase = .filed(sessionId: sessionId, projectName: projectName)
        harkLog("meeting: #\(sessionId) filed as “\(session.title)”\(projectName.map { " under \($0)" } ?? "").")
        // The project assignment changed the searchable scope; re-index.
        onMeetingStored?()
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

enum MeetingFilingError: LocalizedError {
    case notReady
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .notReady: return "The transcript isn't ready yet."
        case .storeUnavailable: return "The Hark database isn't open."
        }
    }
}
