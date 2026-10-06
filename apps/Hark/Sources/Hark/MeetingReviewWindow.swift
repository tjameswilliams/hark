import AppKit
import AVFoundation
import Observation
import SwiftUI

// The post-meeting window. It opens the moment a recording stops, for any
// reason, shows the transcript being produced, and then lets the user name
// the meeting, say who each voice was, and file it under a project
// (existing or new). A meeting that
// is named and assigned, and indexed, is "filed"; one dismissed with Later
// stays in the library under its default title, unassigned, exactly as
// before this window existed.

/// Why the recording stopped. Shown in the window so an automatic stop is
/// never a mystery.
enum MeetingStopReason: Equatable, Sendable {
    case user
    case silence(seconds: Int)
    case captureLost
    case quit

    var label: String {
        switch self {
        case .user: return "Stopped by you."
        case .silence(let seconds):
            let minutes = seconds / 60
            if minutes >= 1 {
                return "Stopped by you after \(minutes) minute\(minutes == 1 ? "" : "s") of silence."
            }
            return "Stopped by you after \(seconds) seconds of silence."
        case .captureLost: return "The audio system restarted; everything captured so far was kept."
        case .quit: return "Hark quit during the recording; the file was closed safely."
        }
    }
}

/// One voice in the meeting, as a row of the "who is this?" step. `name` is
/// what the user edits; it starts as the recognized person, if any.
@MainActor
@Observable
final class ReviewSpeaker: Identifiable {
    let label: String
    var name: String
    /// True when `name` was filled in by a voice match the user has not
    /// reviewed yet.
    let recognized: Bool
    /// A person this voice resembles, not closely enough to fill in.
    let suggestedName: String?
    let talkSeconds: Int
    /// Most of this voice arrived through this Mac's microphone.
    let onLocalMic: Bool
    /// Where in the recording to play this voice from, in seconds.
    let clip: ClosedRange<Double>?
    /// False for meetings recorded before Hark kept voiceprints: the voice
    /// can be named, but not played or learned.
    let hasProfile: Bool

    nonisolated var id: String { label }

    init(_ record: MeetingSpeakerRecord) {
        label = record.label
        name = record.name ?? ""
        recognized = record.name != nil && !record.confirmed
        suggestedName = record.suggestedName
        hasProfile = record.talkMs != nil
        talkSeconds = Int((record.talkMs ?? 0) / 1000)
        onLocalMic = (record.micShare ?? 0) >= 0.7
        if let start = record.clipStartMs, let end = record.clipEndMs, end > start {
            clip = (Double(start) / 1000)...(Double(end) / 1000)
        } else {
            clip = nil
        }
    }

    /// "SPEAKER_01 · 4 min · your microphone". The label is how this voice
    /// reads in the transcript until it has a name.
    var detail: String {
        var parts = [label]
        if hasProfile {
            parts.append(talkSeconds >= 60 ? "\(talkSeconds / 60) min" : "\(talkSeconds) sec")
        }
        if onLocalMic { parts.append("your microphone") }
        return parts.joined(separator: " · ")
    }

    /// Too brief to be worth asking about (a cough, a "yeah"), unless Hark
    /// already has a name or a guess for it.
    var isBrief: Bool {
        hasProfile && talkSeconds < Self.briefSeconds && name.isEmpty && suggestedName == nil
    }
    static let briefSeconds = 5
}

/// One stopped recording on its way to being filed. Owned by the
/// MeetingController, rendered by MeetingReviewView, and mutated only on
/// the main actor.
@MainActor
@Observable
final class MeetingReviewSession: Identifiable {
    enum Phase: Equatable {
        /// Diarizing / transcribing. `stage` is the processor's own progress
        /// line ("diarizing… 40%").
        case processing(stage: String)
        /// Stored in the database; the form can be submitted.
        case ready(sessionId: Int64)
        /// Processing or storage failed. The recording is still on disk.
        case failed(String)
        /// Named, assigned, and handed to the indexer.
        case filed(sessionId: Int64, projectName: String?)
    }

    let id = UUID()
    let startedAt: Date
    let endedAt: Date
    let stopReason: MeetingStopReason
    let audioPath: String
    /// The title the controller stored at record time; the form starts from it.
    let defaultTitle: String

    var phase: Phase = .processing(stage: "Starting…")
    var title: String
    var transcript: String?
    var speakerCount: Int = 0
    var segmentCount: Int = 0
    /// The meeting's voices, longest talker first; empty until processed.
    var speakers: [ReviewSpeaker] = []
    /// Names of everyone named in earlier meetings, to pick from.
    var knownPeople: [String] = []
    /// Failure from the File action itself (distinct from a processing
    /// failure): shown inline, the form stays editable.
    var fileError: String?

    init(startedAt: Date, endedAt: Date, stopReason: MeetingStopReason, audioPath: String, defaultTitle: String) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stopReason = stopReason
        self.audioPath = audioPath
        self.defaultTitle = defaultTitle
        self.title = defaultTitle
    }

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var durationLabel: String {
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
    var storedSessionId: Int64? {
        switch phase {
        case .ready(let id), .filed(let id, _): return id
        default: return nil
        }
    }
}

/// What the view needs from the controller: the project list, and the file
/// action. Kept as a protocol so the view is previewable without a store.
@MainActor
protocol MeetingFiler: AnyObject {
    func projectChoices() -> [(id: Int64, name: String)]
    /// Names the meeting and its speakers (from `session.speakers`), creates
    /// `newProjectName` if given, assigns it, and kicks indexing. Throws on any store failure; the session's phase
    /// becomes .filed on success.
    func file(_ session: MeetingReviewSession, title: String, projectId: Int64?, newProjectName: String?) throws
}

// MARK: - Window

/// One reusable floating window. A new stop replaces its content; the
/// previous session, if still processing, keeps running in the controller
/// and can be found in Recent Meetings when done.
@MainActor
final class MeetingReviewWindowController: NSWindowController, NSWindowDelegate {
    private weak var filer: MeetingFiler?
    private var current: MeetingReviewSession?

    init(filer: MeetingFiler) {
        self.filer = filer
        let window = HarkMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meeting Recorded"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 520)
        // Above the meeting app the user was just in, so the prompt is seen.
        window.level = .floating
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    /// Centers the window on the display the pointer is on: that is where the
    /// user is working, and a prompt that appears on another monitor is a
    /// prompt that gets missed. (Observed: NSWindow.center() picked a
    /// secondary display above the primary one.)
    private func moveToActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.05)
        window.setFrameOrigin(origin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MeetingReviewWindowController is code-only") }

    func show(_ session: MeetingReviewSession) {
        guard let filer else {
            harkLog("meeting review: WARNING — no filer; window not shown.")
            return
        }
        harkLog("meeting review: showing window (\(session.stopReason.label))")
        current = session
        let host = NSHostingView(
            rootView: MeetingReviewView(session: session, filer: filer, close: { [weak self] in
                self?.window?.performClose(nil)
            }))
        // Keep the window at its designed size; by default the hosting view
        // shrinks it to the content's minimum.
        host.sizingOptions = []
        window?.contentView = host
        window?.setContentSize(NSSize(width: 640, height: 700))
        moveToActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        ClipPlayer.shared.stop()
        if let current, case .ready = current.phase {
            harkLog("meeting review: closed without filing; meeting stays as “\(current.defaultTitle)”, unassigned.")
        }
        current = nil
        window?.contentView = nil
    }
}

// MARK: - View

private enum ProjectChoice: Hashable {
    case none
    case existing(Int64)
    case new
}

struct MeetingReviewView: View {
    @Bindable var session: MeetingReviewSession
    let filer: MeetingFiler
    let close: () -> Void

    @State private var projects: [(id: Int64, name: String)] = []
    @State private var choice: ProjectChoice = .none
    @State private var newProjectName = ""
    @FocusState private var titleFocused: Bool

    /// Brand accent (docs/brand.md §3.1), the one primary action per screen.
    private static let rufous = Color(red: 0xb8 / 255, green: 0x43 / 255, blue: 0x2a / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    form
                    speakersSection
                    transcriptSection
                }
                .padding(20)
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            projects = filer.projectChoices()
            titleFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSImage(named: "MenuBarIcon") ?? NSImage())
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(Self.rufous)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting recorded")
                    .font(.title2.weight(.semibold))
                Text("\(session.durationLabel) · started \(session.startedAt.formatted(date: .abbreviated, time: .shortened)). \(session.stopReason.label)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 12) {
            switch session.phase {
            case .processing(let stage):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Making the transcript")
                        .font(.headline)
                    Text(stage.prefix(1).capitalized + stage.dropFirst())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript ready")
                        .font(.headline)
                    Text("\(session.speakerCount) speaker\(session.speakerCount == 1 ? "" : "s") · \(session.segmentCount) segment\(session.segmentCount == 1 ? "" : "s"). Name it, say who spoke, and pick a project to file it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription failed")
                        .font(.headline)
                    Text("\(message) The recording is kept at \(session.audioPath).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .filed(_, let projectName):
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filed")
                        .font(.headline)
                    Text(projectName.map { "“\(session.title)” is in \($0)." } ?? "“\(session.title)” is in your library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Form

    private var isFiled: Bool {
        if case .filed = session.phase { return true }
        return false
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.semibold))
                TextField("What was this meeting?", text: $session.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .disabled(isFiled)
                    .onSubmit { if canFile { fileNow() } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Project").font(.subheadline.weight(.semibold))
                Picker("Project", selection: $choice) {
                    Text("No project").tag(ProjectChoice.none)
                    if !projects.isEmpty {
                        Divider()
                        ForEach(projects, id: \.id) { project in
                            Text(project.name).tag(ProjectChoice.existing(project.id))
                        }
                    }
                    Divider()
                    Text("New Project…").tag(ProjectChoice.new)
                }
                .labelsHidden()
                .disabled(isFiled)
                if choice == .new {
                    TextField("New project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isFiled)
                        .onSubmit { if canFile { fileNow() } }
                }
            }
            if let error = session.fileError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    // MARK: Speakers

    private var listedSpeakers: [ReviewSpeaker] {
        session.speakers.filter { !$0.isBrief }
    }

    @ViewBuilder
    private var speakersSection: some View {
        let listed = listedSpeakers
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speakers").font(.subheadline.weight(.semibold))
                Text("Play a voice and say who it is. Hark recognizes people you have named before, and learns from each one you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(listed) { speaker in
                        SpeakerRow(
                            speaker: speaker, audioPath: session.audioPath,
                            knownPeople: session.knownPeople, disabled: isFiled)
                        if speaker.id != listed.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                let hidden = session.speakers.count - listed.count
                if hidden > 0 {
                    Text("\(hidden) brief voice\(hidden == 1 ? "" : "s") under \(ReviewSpeaker.briefSeconds) seconds not listed.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcript").font(.subheadline.weight(.semibold))
                Spacer()
                if let transcript = session.transcript {
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(transcript, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            Group {
                if let transcript = session.transcript {
                    Text(transcript.isEmpty ? "No speech was detected in this recording." : transcript)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    Text(placeholderForPhase)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .padding(12)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var placeholderForPhase: String {
        switch session.phase {
        case .processing: return "The transcript appears here when it is ready."
        case .failed: return "No transcript."
        default: return ""
        }
    }

    // MARK: Footer

    private var canFile: Bool {
        guard session.isReady else { return false }
        if choice == .new, newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var footer: some View {
        HStack {
            if case .processing = session.phase {
                Text("You can name it now; filing waits for the transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isFiled {
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Later") { close() }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep the meeting under its default name, unassigned. It stays in Recent Meetings.")
                Button("File Meeting") { fileNow() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Self.rufous)
                    .disabled(!canFile)
            }
        }
    }

    private func fileNow() {
        guard canFile else { return }
        var projectId: Int64?
        var newName: String?
        switch choice {
        case .none: break
        case .existing(let id): projectId = id
        case .new: newName = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try filer.file(session, title: session.title, projectId: projectId, newProjectName: newName)
            session.fileError = nil
            // Give the confirmation a beat, then get out of the way.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                close()
            }
        } catch {
            session.fileError = "Couldn't file the meeting: \(error.localizedDescription)"
        }
    }
}


// MARK: - Speaker row

/// One voice: play it, name it. Shared by the post-meeting window and the
/// library's speaker sheet.
struct SpeakerRow: View {
    @Bindable var speaker: ReviewSpeaker
    /// The meeting recording; nil when it is no longer on disk.
    let audioPath: String?
    let knownPeople: [String]
    let disabled: Bool

    private var player: ClipPlayer { ClipPlayer.shared }
    private var isPlaying: Bool { player.playing == speaker.label }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isPlaying {
                    player.stop()
                } else if let clip = speaker.clip, let audioPath {
                    player.play(label: speaker.label, path: audioPath, clip: clip)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(speaker.clip == nil || audioPath == nil)
            .help(isPlaying ? "Stop" : "Play a few seconds of this voice")
            .accessibilityLabel(isPlaying ? "Stop" : "Play this voice")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    TextField("Who is this?", text: $speaker.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    if !knownPeople.isEmpty {
                        Menu {
                            ForEach(knownPeople, id: \.self) { person in
                                Button(person) { speaker.name = person }
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Pick someone you have named before")
                    }
                }
                .disabled(disabled)
                detail
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var detail: some View {
        HStack(spacing: 6) {
            Text(speaker.detail)
                .foregroundStyle(.secondary)
            if speaker.recognized, !speaker.name.isEmpty {
                Label("Recognized by voice", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            } else if let suggestion = speaker.suggestedName, speaker.name.isEmpty, !disabled {
                Button("Sounds like \(suggestion)") { speaker.name = suggestion }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }
}

/// Plays one speaker's clip from the meeting recording. The recording keeps
/// the mic and the system audio in separate channels, so the clip is mixed
/// to mono first — otherwise a remote voice plays in one ear only.
@MainActor
@Observable
final class ClipPlayer {
    static let shared = ClipPlayer()

    /// Label of the speaker whose clip is playing, if any.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var finish: Task<Void, Never>?

    func play(label: String, path: String, clip: ClosedRange<Double>) {
        stop()
        do {
            let player = try AVAudioPlayer(data: Self.monoWav(path: path, clip: clip))
            guard player.play() else { throw ClipError.wouldNotPlay }
            self.player = player
            playing = label
            finish = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            harkLog("meeting review: WARNING — could not play the clip for \(label): \(error)")
        }
    }

    func stop() {
        finish?.cancel()
        finish = nil
        player?.stop()
        player = nil
        playing = nil
    }

    private enum ClipError: Error { case empty, wouldNotPlay }

    /// The clip as an in-memory 16-bit mono WAV, peak-normalized so a quiet
    /// remote voice is as audible as a close microphone.
    private static func monoWav(path: String, clip: ClosedRange<Double>) throws -> Data {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let start = AVAudioFramePosition(clip.lowerBound * format.sampleRate)
        let wanted = AVAudioFrameCount((clip.upperBound - clip.lowerBound) * format.sampleRate)
        guard start < file.length, wanted > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted)
        else { throw ClipError.empty }
        file.framePosition = start
        try file.read(into: buffer, frameCount: wanted)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { throw ClipError.empty }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<frames { mono[i] += channels[channel][i] }
        }
        let peak = mono.reduce(0) { max($0, abs($1)) }
        let gain = peak > 0 ? min(0.7 / peak, 30) : 1

        let sampleRate = UInt32(format.sampleRate)
        let dataBytes = UInt32(frames * 2)
        var wav = Data(capacity: 44 + frames * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(36 + dataBytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataBytes)
        for sample in mono {
            append(Int16(max(-1, min(1, sample * gain)) * Float(Int16.max)))
        }
        return wav
    }
}

// MARK: - The silence question

/// "Still recording?" Raised by the MeetingController's silence monitor,
/// answered by the two buttons, withdrawn on its own if sound resumes.
@MainActor
@Observable
final class SilencePrompt {
    var quietSeconds: Int
    /// False when the recording has carried no sound at all since it began.
    let heardAnything: Bool
    let startedAt: Date
    /// Set by the controller when the question no longer applies (sound
    /// resumed, the user answered from elsewhere, or the recording stopped).
    var isDismissed = false

    init(quietSeconds: Int, heardAnything: Bool, startedAt: Date) {
        self.quietSeconds = quietSeconds
        self.heardAnything = heardAnything
        self.startedAt = startedAt
    }

    var quietLabel: String {
        let m = quietSeconds / 60
        if m >= 1 { return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(quietSeconds) seconds"
    }
}

/// Small floating panel on the display under the pointer. Non-modal: the
/// recording carries on until the user answers, and the panel closes itself
/// when sound comes back.
@MainActor
final class SilencePromptWindowController: NSWindowController, NSWindowDelegate {
    private weak var meeting: MeetingController?
    private var observation: Task<Void, Never>?

    init(meeting: MeetingController) {
        self.meeting = meeting
        let window = HarkMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Hark"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SilencePromptWindowController is code-only") }

    func show(_ prompt: SilencePrompt) {
        guard let meeting, let window else { return }
        let host = NSHostingView(rootView: SilencePromptView(
            prompt: prompt,
            keep: { [weak meeting] in meeting?.keepRecording() },
            stop: { [weak meeting] in meeting?.stopAfterSilence() }))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 420, height: 170))
        // Same placement rule as the review window: where the pointer is.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.midX - 210, y: v.midY + v.height * 0.18))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Close when the controller withdraws the question.
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if prompt.isDismissed {
                    self?.window?.orderOut(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Closing the panel with its close button is a "keep recording".
    func windowWillClose(_ notification: Notification) {
        observation?.cancel()
        observation = nil
        if let meeting, meeting.isRecording {
            meeting.keepRecording()
        }
        window?.contentView = nil
    }
}

struct SilencePromptView: View {
    @Bindable var prompt: SilencePrompt
    let keep: () -> Void
    let stop: () -> Void

    private static let rufous = Color(red: 0xb8 / 255, green: 0x43 / 255, blue: 0x2a / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSImage(named: "MenuBarIcon") ?? NSImage())
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Self.rufous)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Still recording?")
                        .font(.headline)
                    Text(prompt.heardAnything
                         ? "Nothing has been heard for \(prompt.quietLabel). If the meeting is over, stop now and Hark will make the transcript."
                         : "No sound has reached Hark since the recording started \(prompt.quietLabel) ago. Check the input device, or stop if this was a false start.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Recording continues until you answer.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Keep Recording") { keep() }
                    .keyboardShortcut(.cancelAction)
                Button("Stop Recording") { stop() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Self.rufous)
            }
        }
        .padding(18)
        .frame(width: 420, height: 170)
    }
}
