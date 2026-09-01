import Foundation

// The knowledge backend contract for the management window. A parallel agent
// is building the real (Rust-core-backed) implementation; the UI depends only
// on this protocol so the swap is one line in HarkApp. Do not change these
// signatures without coordinating both sides.

struct KSearchHit: Identifiable, Sendable {
    var id: Int64 { chunkId }
    let sessionId: Int64
    let chunkId: Int64
    let kind: String          // "dictation" | "meeting"
    let title: String?
    let startedAt: String     // ISO-8601
    let snippet: String
    let score: Double
    let tStartMs: Int64
    let speaker: String?
}
struct KSessionSummary: Identifiable, Sendable {
    let id: Int64
    let kind: String
    let title: String?
    let startedAt: String
    let projectId: Int64?
    let segmentCount: Int64
    let speakerCount: Int64
    let preview: String
}
struct KProject: Identifiable, Sendable {
    let id: Int64
    let name: String
    let description: String?
    let sessionCount: Int64
}

@MainActor
protocol KnowledgeService: AnyObject {
    func listProjects() throws -> [KProject]
    func createProject(name: String, description: String?) throws -> Int64
    func deleteProject(id: Int64) throws
    func assignSession(sessionId: Int64, projectId: Int64?) throws
    func listSessions(kind: String?, projectId: Int64?, limit: UInt32, offset: UInt32) throws -> [KSessionSummary]
    func transcript(sessionId: Int64) throws -> String
    func search(query: String, projectId: Int64?, kind: String?, limit: UInt32) async throws -> [KSearchHit]
    func indexPending() async throws -> UInt32
}

// MARK: - Mock backend

enum KnowledgeMockError: LocalizedError {
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let what): return "\(what) not found"
        }
    }
}

/// MOCK — in-memory stand-in for the real Rust-core-backed knowledge service.
/// Ships so the window is fully exercisable before the backend lands; replace
/// the `MockKnowledgeService()` construction in HarkApp with the real service
/// when it exists. Nothing here persists across launches.
@MainActor
final class MockKnowledgeService: KnowledgeService {
    private struct Chunk {
        let id: Int64
        let tStartMs: Int64
        let speaker: String?
        let text: String
    }
    private struct Session {
        let id: Int64
        let kind: String          // "dictation" | "meeting"
        let title: String?
        let startedAt: String
        var projectId: Int64?
        let chunks: [Chunk]
    }
    private struct Project {
        let id: Int64
        var name: String
        var description: String?
    }

    private var projects: [Project]
    private var sessions: [Session]
    private var nextProjectId: Int64 = 3

    init() {
        func iso(daysAgo: Double) -> String {
            Date(timeIntervalSinceNow: -daysAgo * 86_400).ISO8601Format()
        }
        projects = [
            Project(id: 1, name: "Hark Development",
                    description: "Standups and design notes for Hark itself."),
            Project(id: 2, name: "Acme Redesign",
                    description: "Client meetings and dictated notes for the Acme site redesign."),
        ]
        sessions = [
            Session(
                id: 101, kind: "meeting", title: "Sprint Planning — Hark",
                startedAt: iso(daysAgo: 4), projectId: 1,
                chunks: [
                    Chunk(id: 10100, tStartMs: 4_000, speaker: "Speaker 1",
                          text: "Okay, sprint planning. The big item this week is the management window: browsing, search, and the ask feature."),
                    Chunk(id: 10101, tStartMs: 22_000, speaker: "Speaker 2",
                          text: "Search should go through the FTS5 index in the store, not a linear scan. Snippets need the timestamp so you can jump back into the meeting."),
                    Chunk(id: 10102, tStartMs: 58_000, speaker: "Speaker 1",
                          text: "Agreed. Let's debounce the search field at around three hundred milliseconds so we don't hammer the index on every keystroke."),
                    Chunk(id: 10103, tStartMs: 95_000, speaker: "Speaker 2",
                          text: "For the ask feature we reuse the local cleanup endpoint. Retrieve the top eight chunks, number them, and have the model cite them."),
                    Chunk(id: 10104, tStartMs: 140_000, speaker: "Speaker 1",
                          text: "Projects are just a nullable column on sessions. Deleting a project reverts its sessions to unassigned, never deletes them."),
                ]),
            Session(
                id: 102, kind: "meeting", title: "Acme Kickoff",
                startedAt: iso(daysAgo: 7), projectId: 2,
                chunks: [
                    Chunk(id: 10200, tStartMs: 6_000, speaker: "Speaker 1",
                          text: "Thanks everyone for joining. Goal today is scope and timeline for the Acme site redesign."),
                    Chunk(id: 10201, tStartMs: 31_000, speaker: "Speaker 2",
                          text: "Budget is forty thousand for phase one. That covers the homepage, the pricing page, and the design system."),
                    Chunk(id: 10202, tStartMs: 74_000, speaker: "Speaker 3",
                          text: "Timeline-wise we want a first review by the end of September and launch before the November conference."),
                    Chunk(id: 10203, tStartMs: 120_000, speaker: "Speaker 1",
                          text: "Action items: I'll send the contract, Dana owns the moodboards, and we meet weekly on Thursdays."),
                ]),
            Session(
                id: 103, kind: "meeting", title: "Weekly Standup",
                startedAt: iso(daysAgo: 1), projectId: 1,
                chunks: [
                    Chunk(id: 10300, tStartMs: 3_000, speaker: "Speaker 1",
                          text: "Quick standup. Diarization is stable now; the speaker merge bug from last week is fixed."),
                    Chunk(id: 10301, tStartMs: 30_000, speaker: "Speaker 2",
                          text: "I'm on the knowledge backend: embeddings table, chunking, and the indexer that catches up on pending sessions."),
                    Chunk(id: 10302, tStartMs: 66_000, speaker: "Speaker 1",
                          text: "Blocker: the paste engine needs Accessibility re-granted after every ad-hoc signed build. Developer ID signing fixes it."),
                ]),
            Session(
                id: 104, kind: "dictation", title: nil,
                startedAt: iso(daysAgo: 0.2), projectId: 1,
                chunks: [
                    Chunk(id: 10400, tStartMs: 0, speaker: nil,
                          text: "Idea for the window: when a search hit is clicked, select the session and scroll the transcript to the matching timestamp."),
                ]),
            Session(
                id: 105, kind: "dictation", title: nil,
                startedAt: iso(daysAgo: 2.1), projectId: 2,
                chunks: [
                    Chunk(id: 10500, tStartMs: 0, speaker: nil,
                          text: "Draft an intro email to the Acme team recapping the kickoff: forty thousand budget for phase one, review end of September, launch before the conference."),
                ]),
            Session(
                id: 106, kind: "dictation", title: nil,
                startedAt: iso(daysAgo: 3.4), projectId: nil,
                chunks: [
                    Chunk(id: 10600, tStartMs: 0, speaker: nil,
                          text: "Remember to renew the Developer ID certificate before it expires next month, and to file the September invoices."),
                ]),
            Session(
                id: 107, kind: "dictation", title: nil,
                startedAt: iso(daysAgo: 5.5), projectId: nil,
                chunks: [
                    Chunk(id: 10700, tStartMs: 0, speaker: nil,
                          text: "Note to self: the microphone permission silently fails if the audio engine starts before the grant lands. Restart the engine when captured audio is pure silence."),
                ]),
        ]
    }

    // MARK: Projects

    func listProjects() throws -> [KProject] {
        projects.map { p in
            KProject(
                id: p.id, name: p.name, description: p.description,
                sessionCount: Int64(sessions.count(where: { $0.projectId == p.id })))
        }
    }

    func createProject(name: String, description: String?) throws -> Int64 {
        let id = nextProjectId
        nextProjectId += 1
        projects.append(Project(id: id, name: name, description: description))
        return id
    }

    func deleteProject(id: Int64) throws {
        guard projects.contains(where: { $0.id == id }) else {
            throw KnowledgeMockError.notFound("project #\(id)")
        }
        projects.removeAll { $0.id == id }
        // Sessions revert to unassigned; they are never deleted with a project.
        for i in sessions.indices where sessions[i].projectId == id {
            sessions[i].projectId = nil
        }
    }

    func assignSession(sessionId: Int64, projectId: Int64?) throws {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw KnowledgeMockError.notFound("session #\(sessionId)")
        }
        if let projectId, !projects.contains(where: { $0.id == projectId }) {
            throw KnowledgeMockError.notFound("project #\(projectId)")
        }
        sessions[i].projectId = projectId
    }

    // MARK: Sessions

    func listSessions(kind: String?, projectId: Int64?, limit: UInt32, offset: UInt32) throws -> [KSessionSummary] {
        let filtered = sessions
            .filter { kind == nil || $0.kind == kind }
            .filter { projectId == nil || $0.projectId == projectId }
            .sorted { $0.startedAt > $1.startedAt }   // ISO-8601 sorts lexically
        let page = filtered.dropFirst(Int(offset)).prefix(Int(limit))
        return page.map { s in
            let speakers = Set(s.chunks.compactMap(\.speaker))
            let preview = s.chunks.first?.text ?? ""
            return KSessionSummary(
                id: s.id, kind: s.kind, title: s.title, startedAt: s.startedAt,
                projectId: s.projectId,
                segmentCount: Int64(s.chunks.count),
                speakerCount: Int64(speakers.count),
                preview: String(preview.prefix(120)))
        }
    }

    func transcript(sessionId: Int64) throws -> String {
        guard let s = sessions.first(where: { $0.id == sessionId }) else {
            throw KnowledgeMockError.notFound("session #\(sessionId)")
        }
        if s.kind == "meeting" {
            return s.chunks.map { chunk in
                let stamp = KFormat.mmss(chunk.tStartMs)
                let speaker = chunk.speaker ?? "Speaker"
                return "[\(stamp)] \(speaker): \(chunk.text)"
            }.joined(separator: "\n\n")
        }
        return s.chunks.map(\.text).joined(separator: "\n\n")
    }

    // MARK: Search

    func search(query: String, projectId: Int64?, kind: String?, limit: UInt32) async throws -> [KSearchHit] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        let terms = needle.split(separator: " ").map(String.init)
        var hits: [KSearchHit] = []
        for s in sessions {
            if let kind, s.kind != kind { continue }
            if let projectId, s.projectId != projectId { continue }
            for chunk in s.chunks {
                let haystack = chunk.text.lowercased()
                let matched = terms.filter { haystack.contains($0) }
                guard !matched.isEmpty else { continue }
                hits.append(KSearchHit(
                    sessionId: s.id, chunkId: chunk.id, kind: s.kind,
                    title: s.title, startedAt: s.startedAt,
                    snippet: String(chunk.text.prefix(200)),
                    score: Double(matched.count) / Double(terms.count),
                    tStartMs: chunk.tStartMs, speaker: chunk.speaker))
            }
        }
        hits.sort { ($0.score, $0.startedAt) > ($1.score, $1.startedAt) }
        return Array(hits.prefix(Int(limit)))
    }

    func indexPending() async throws -> UInt32 {
        0  // the mock has nothing to index
    }
}
