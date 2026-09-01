import Foundation

enum KnowledgeError: LocalizedError {
    case storeUnavailable
    var errorDescription: String? {
        "The Hark database isn't open yet — try again in a moment."
    }
}

/// KnowledgeService backed by the Rust core (hark-core over UniFFI).
/// Fast SQLite reads run on the main actor; embedding-heavy calls (search,
/// indexing — the first of which downloads the ~34 MB embedding model) run
/// detached so the UI never blocks.
@MainActor
final class RealKnowledgeService: KnowledgeService {
    private let storeProvider: () -> HarkStore?
    private let modelCacheDir: String
    /// Debounced auto-index task, kicked after each stored dictation/meeting.
    private var pendingIndex: Task<Void, Never>?

    init(storeProvider: @escaping () -> HarkStore?) {
        self.storeProvider = storeProvider
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("Hark/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.modelCacheDir = dir.path
    }

    private func store() throws -> HarkStore {
        guard let store = storeProvider() else { throw KnowledgeError.storeUnavailable }
        return store
    }

    // MARK: - Projects

    func listProjects() throws -> [KProject] {
        try store().listProjects().map {
            KProject(id: $0.id, name: $0.name, description: $0.description,
                     sessionCount: $0.sessionCount)
        }
    }

    func createProject(name: String, description: String?) throws -> Int64 {
        try store().createProject(name: name, description: description)
    }

    func deleteProject(id: Int64) throws {
        try store().deleteProject(id: id)
    }

    func assignSession(sessionId: Int64, projectId: Int64?) throws {
        try store().assignSession(sessionId: sessionId, projectId: projectId)
    }

    // MARK: - Sessions

    func listSessions(
        kind: String?, projectId: Int64?, limit: UInt32, offset: UInt32
    ) throws -> [KSessionSummary] {
        try store()
            .listSessions(kind: kind, projectId: projectId, limit: limit, offset: offset)
            .map {
                KSessionSummary(
                    id: $0.id, kind: $0.kind, title: $0.title, startedAt: $0.startedAt,
                    projectId: $0.projectId, segmentCount: $0.segmentCount,
                    speakerCount: $0.speakerCount, preview: $0.preview)
            }
    }

    func transcript(sessionId: Int64) throws -> String {
        try store().sessionTranscript(id: sessionId)
    }

    // MARK: - Search & indexing

    func search(
        query: String, projectId: Int64?, kind: String?, limit: UInt32
    ) async throws -> [KSearchHit] {
        let store = try store()
        let dir = modelCacheDir
        let hits = try await Task.detached(priority: .userInitiated) {
            try store.search(
                query: query, projectId: projectId, kind: kind,
                limit: limit, modelCacheDir: dir)
        }.value
        return hits.map {
            KSearchHit(
                sessionId: $0.sessionId, chunkId: $0.chunkId, kind: $0.kind,
                title: $0.title, startedAt: $0.startedAt, snippet: $0.snippet,
                score: $0.score, tStartMs: $0.tStartMs, speaker: $0.speaker)
        }
    }

    @discardableResult
    func indexPending() async throws -> UInt32 {
        let store = try store()
        let dir = modelCacheDir
        return try await Task.detached(priority: .utility) {
            try store.indexPending(modelCacheDir: dir)
        }.value
    }

    /// Kicked after every stored dictation/meeting; debounced so a burst of
    /// dictations embeds once. Failures are logged, never surfaced — the next
    /// kick or window-open retries.
    func indexSoon() {
        pendingIndex?.cancel()
        pendingIndex = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            do {
                let indexed = try await self.indexPending()
                if indexed > 0 { harkLog("knowledge: indexed \(indexed) session(s).") }
            } catch {
                harkLog("knowledge: background indexing failed (\(error)) — will retry on next kick.")
            }
        }
    }
}
