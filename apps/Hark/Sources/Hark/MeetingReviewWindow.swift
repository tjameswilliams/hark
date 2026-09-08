import AppKit
import Observation
import SwiftUI

// The post-meeting window. It opens the moment a recording stops, for any
// reason, shows the transcript being produced, and then lets the user name
// the meeting and file it under a project (existing or new). A meeting that
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
            if minutes >= 1, seconds % 60 == 0 {
                return "Stopped after \(minutes) minute\(minutes == 1 ? "" : "s") of silence."
            }
            return "Stopped after \(seconds) seconds of silence."
        case .captureLost: return "The audio system restarted; everything captured so far was kept."
        case .quit: return "Hark quit during the recording; the file was closed safely."
        }
    }
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
    /// Names the meeting, creates `newProjectName` if given, assigns it, and
    /// kicks indexing. Throws on any store failure; the session's phase
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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
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
        window?.setContentSize(NSSize(width: 640, height: 620))
        moveToActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
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
                    Text("\(session.speakerCount) speaker\(session.speakerCount == 1 ? "" : "s") · \(session.segmentCount) segment\(session.segmentCount == 1 ? "" : "s"). Name it and pick a project to file it.")
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
