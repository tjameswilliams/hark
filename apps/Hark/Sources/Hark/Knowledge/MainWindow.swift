import AppKit
import Observation
import SwiftUI

// The management window: browse/search meetings & dictations, organize them
// into projects, and ask questions over them. Hark stays a menu-bar-only app
// (.accessory) even while this window is open — one icon total, the bird.

// MARK: - Formatting helpers

enum KFormat {
    @MainActor private static let isoPlain = ISO8601DateFormatter()
    @MainActor private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    @MainActor private static let relative = RelativeDateTimeFormatter()

    @MainActor static func date(_ iso: String) -> Date? {
        isoPlain.date(from: iso) ?? isoFractional.date(from: iso)
    }
    @MainActor static func relativeString(_ iso: String) -> String {
        guard let date = date(iso) else { return iso }
        return relative.localizedString(for: date, relativeTo: Date())
    }
    @MainActor static func absoluteString(_ iso: String) -> String {
        guard let date = date(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    /// 83_000 ms -> "01:23". Nonisolated: also used when building LLM context.
    static func mmss(_ ms: Int64) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    /// "Meeting" / "Dictation" fallback title.
    static func displayTitle(_ title: String?, kind: String) -> String {
        title ?? (kind == "meeting" ? "Meeting" : "Dictation")
    }
}

// MARK: - View model

enum SidebarItem: Hashable {
    case all, dictations, meetings
    case project(Int64)
}

enum ContentTab: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case ask = "Ask"
    var id: String { rawValue }
}

/// All window state, backed by a KnowledgeService. Every service call is
/// wrapped: failures become UI text (banner, alert, or a chat message), never
/// a crash — same fail-open posture as the rest of the app.
@MainActor
@Observable
final class KnowledgeModel {
    let service: KnowledgeService
    private static let pageSize: UInt32 = 50

    struct SessionHeader {
        var id: Int64
        var kind: String
        var title: String?
        var startedAt: String
        var projectId: Int64?
    }

    // Sidebar
    var sidebarSelection: SidebarItem? = .all {
        didSet { if sidebarSelection != oldValue { scopeChanged() } }
    }
    private(set) var projects: [KProject] = []
    var showNewProjectSheet = false
    var projectPendingDelete: KProject?

    // Content
    var contentTab: ContentTab = .browse
    private(set) var sessions: [KSessionSummary] = []
    private(set) var canLoadMore = false
    private(set) var listError: String?
    var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged() } }
    }
    private(set) var searchHits: [KSearchHit] = []
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?

    // Detail
    var selectedSessionId: Int64? {
        didSet { if selectedSessionId != oldValue { selectionChanged() } }
    }
    private(set) var selectedHeader: SessionHeader?
    private(set) var transcriptText: String?
    private(set) var transcriptError: String?

    // Ask
    var askMessages: [AskMessage] = []
    private(set) var askPending = false

    // Transient failures from actions (create/delete/assign).
    var actionError: String?

    init(service: KnowledgeService) {
        self.service = service
    }

    // MARK: Scope

    var scopeKind: String? {
        switch sidebarSelection ?? .all {
        case .dictations: return "dictation"
        case .meetings: return "meeting"
        default: return nil
        }
    }
    var scopeProjectId: Int64? {
        if case .project(let id) = sidebarSelection ?? .all { return id }
        return nil
    }
    var scopeDescription: String {
        switch sidebarSelection ?? .all {
        case .all: return "everything"
        case .dictations: return "dictations"
        case .meetings: return "meetings"
        case .project(let id):
            return projects.first(where: { $0.id == id })?.name ?? "this project"
        }
    }

    private func scopeChanged() {
        searchText = ""   // clears hits + cancels any in-flight search
        reloadSessions()
    }

    // MARK: Loading

    /// Called every time the window is shown: refresh lists and (fire and
    /// forget) let the backend index anything recorded since last time.
    func refreshAll() {
        reloadProjects()
        reloadSessions()
        Task { [service] in
            do {
                let indexed = try await service.indexPending()
                if indexed > 0 { harkLog("knowledge: indexed \(indexed) pending session(s).") }
            } catch {
                harkLog("knowledge: background indexing failed (non-fatal): \(error)")
            }
        }
    }

    func reloadProjects() {
        do {
            projects = try service.listProjects()
        } catch {
            actionError = "Couldn't load projects: \(error.localizedDescription)"
        }
    }

    func reloadSessions() {
        sessions = []
        canLoadMore = false
        loadMoreSessions()
    }

    func loadMoreSessions() {
        do {
            let page = try service.listSessions(
                kind: scopeKind, projectId: scopeProjectId,
                limit: Self.pageSize, offset: UInt32(sessions.count))
            sessions.append(contentsOf: page)
            canLoadMore = page.count == Int(Self.pageSize)
            listError = nil
        } catch {
            listError = "Couldn't load sessions: \(error.localizedDescription)"
            canLoadMore = false
        }
    }

    // MARK: Search (debounced ~300 ms)

    private func searchTextChanged() {
        searchTask?.cancel()
        searchTask = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        let kind = scopeKind
        let projectId = scopeProjectId
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))   // throws on cancel
                guard let self else { return }
                let hits = try await self.service.search(
                    query: query, projectId: projectId, kind: kind, limit: 50)
                guard !Task.isCancelled else { return }
                self.searchHits = hits
                self.isSearching = false
                self.listError = nil
            } catch is CancellationError {
                // Superseded by a newer keystroke (or a cleared field) —
                // that call owns the UI state now.
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.searchHits = []
                self.isSearching = false
                self.listError = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Selection / transcript

    private func selectionChanged() {
        guard let id = selectedSessionId else {
            selectedHeader = nil
            transcriptText = nil
            transcriptError = nil
            return
        }
        if let s = sessions.first(where: { $0.id == id }) {
            selectedHeader = SessionHeader(
                id: s.id, kind: s.kind, title: s.title,
                startedAt: s.startedAt, projectId: s.projectId)
        } else if selectedHeader?.id != id {
            // Selected from a search hit or citation outside the loaded list.
            if let h = searchHits.first(where: { $0.sessionId == id }) {
                selectedHeader = SessionHeader(
                    id: id, kind: h.kind, title: h.title,
                    startedAt: h.startedAt, projectId: nil)
            } else {
                selectedHeader = SessionHeader(
                    id: id, kind: "dictation", title: "Session #\(id)",
                    startedAt: "", projectId: nil)
            }
        }
        loadTranscript(id)
    }

    /// Select the session a search hit / citation points at.
    func select(hit: KSearchHit) {
        selectedHeader = SessionHeader(
            id: hit.sessionId, kind: hit.kind, title: hit.title,
            startedAt: hit.startedAt,
            projectId: sessions.first(where: { $0.id == hit.sessionId })?.projectId)
        if selectedSessionId == hit.sessionId {
            loadTranscript(hit.sessionId)
        } else {
            selectedSessionId = hit.sessionId
        }
    }

    private func loadTranscript(_ id: Int64) {
        do {
            transcriptText = try service.transcript(sessionId: id)
            transcriptError = nil
        } catch {
            transcriptText = nil
            transcriptError = "Couldn't load the transcript: \(error.localizedDescription)"
        }
    }

    // MARK: Project actions

    func createProject(name: String, description: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id = try service.createProject(
                name: trimmedName, description: (desc?.isEmpty ?? true) ? nil : desc)
            reloadProjects()
            sidebarSelection = .project(id)
        } catch {
            actionError = "Couldn't create the project: \(error.localizedDescription)"
        }
    }

    func deleteProject(_ project: KProject) {
        do {
            try service.deleteProject(id: project.id)
            if sidebarSelection == .project(project.id) {
                sidebarSelection = .all      // also reloads sessions
            } else {
                reloadSessions()             // projectIds changed underneath
            }
            reloadProjects()
            if selectedHeader?.projectId == project.id {
                selectedHeader?.projectId = nil
            }
        } catch {
            actionError = "Couldn't delete the project: \(error.localizedDescription)"
        }
    }

    func assignSelectedSession(to projectId: Int64?) {
        guard let id = selectedSessionId else { return }
        do {
            try service.assignSession(sessionId: id, projectId: projectId)
            selectedHeader?.projectId = projectId
            reloadProjects()
            reloadSessions()
        } catch {
            actionError = "Couldn't move the session: \(error.localizedDescription)"
        }
    }

    // MARK: Ask

    func sendQuestion(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !askPending else { return }
        askMessages.append(AskMessage(role: .user, text: question))
        askPending = true
        let kind = scopeKind
        let projectId = scopeProjectId
        let scope = scopeDescription
        Task { [weak self] in
            guard let self else { return }
            defer { self.askPending = false }
            let hits: [KSearchHit]
            do {
                hits = try await self.service.search(
                    query: question, projectId: projectId, kind: kind, limit: 8)
            } catch {
                self.askMessages.append(AskMessage(
                    role: .assistant, isError: true,
                    text: "Couldn't search \(scope): \(error.localizedDescription)"))
                return
            }
            guard !hits.isEmpty else {
                self.askMessages.append(AskMessage(
                    role: .assistant, isError: true,
                    text: "No matching excerpts in \(scope) — nothing to ground an answer in. Try rephrasing, or a broader scope."))
                return
            }
            let engine = AskEngine.fromDefaults()
            switch await engine.answer(question: question, hits: hits) {
            case .answer(let text):
                self.askMessages.append(AskMessage(
                    role: .assistant, text: text, citations: hits))
            case .failure(let reason):
                self.askMessages.append(AskMessage(
                    role: .assistant, isError: true,
                    text: "Couldn't reach the model at \(engine.urlString) — \(reason)."))
            }
        }
    }
}

// MARK: - Window

/// Hark has no main menu (menu-bar app), so the standard key equivalents
/// never route through NSMenu. Handle the essentials at the window instead:
/// close, minimize, quit, and text editing in the search/ask fields.
final class HarkMainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chars = event.charactersIgnoringModifiers else { return false }
        if flags == [.command, .shift], chars.lowercased() == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        guard flags == .command else { return false }
        switch chars {
        case "w": performClose(nil); return true
        case "m": performMiniaturize(nil); return true
        case "q": NSApp.terminate(nil); return true
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        default: return false
        }
    }
}

/// Single reusable management window. The app stays .accessory (menu-bar
/// only, no Dock icon) — accessory apps can still take key focus, and the
/// window handles its own ⌘-key equivalents (see HarkMainWindow above).
@MainActor
final class MainWindowController: NSWindowController {
    private let model: KnowledgeModel

    init(knowledge: KnowledgeService) {
        self.model = KnowledgeModel(service: knowledge)
        let window = HarkMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Hark"
        window.isReleasedWhenClosed = false   // one reusable window
        window.minSize = NSSize(width: 860, height: 520)
        window.center()
        window.setFrameAutosaveName("HarkMainWindow")
        window.contentView = NSHostingView(rootView: MainWindowRootView(model: model))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MainWindowController is code-only") }

    /// Opens (or raises) the window and brings Hark to the foreground.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshAll()
    }
}

// MARK: - Root layout

struct MainWindowRootView: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            SessionListPane(model: model)
                .navigationSplitViewColumnWidth(min: 330, ideal: 400)
        } detail: {
            TranscriptPane(model: model)
        }
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            // The one hawk accent: the same bird as the status item.
            ToolbarItem(placement: .navigation) {
                Image(systemName: "bird")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Hark")
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }
}
