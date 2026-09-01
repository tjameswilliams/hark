import SwiftUI

/// Middle column: Browse / Ask tab switch. Browse is the searchable session
/// list for the current sidebar scope; Ask is the retrieval-grounded chat.
struct SessionListPane: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $model.contentTab) {
                ForEach(ContentTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            switch model.contentTab {
            case .browse:
                BrowseList(model: model)
            case .ask:
                AskView(model: model)
            }
        }
    }
}

// MARK: - Browse

struct BrowseList: View {
    @Bindable var model: KnowledgeModel

    private var queryActive: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if let error = model.listError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if queryActive {
                hitList
            } else {
                sessionList
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: $model.searchText)
                .textFieldStyle(.plain)
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .quaternarySystemFill)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var sessionList: some View {
        List(selection: $model.selectedSessionId) {
            ForEach(model.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
            }
            if model.canLoadMore {
                HStack {
                    Spacer()
                    Button("Load More") { model.loadMoreSessions() }
                        .buttonStyle(.link)
                    Spacer()
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty && model.listError == nil {
                ContentUnavailableView(
                    "Nothing Here Yet", systemImage: "tray",
                    description: Text("Dictations and meeting recordings will show up in this list."))
            }
        }
    }

    private var hitList: some View {
        List {
            ForEach(model.searchHits) { hit in
                SearchHitRow(hit: hit, isSelected: model.selectedSessionId == hit.sessionId)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(hit: hit) }
            }
        }
        .overlay {
            if model.searchHits.isEmpty && !model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct SessionRow: View {
    let session: KSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(KFormat.displayTitle(session.title, kind: session.kind))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                KindBadge(kind: session.kind)
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(KFormat.relativeString(session.startedAt))
                if session.kind == "meeting" {
                    Text("·")
                    Text("\(session.speakerCount) speaker\(session.speakerCount == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

struct SearchHitRow: View {
    let hit: KSearchHit
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(KFormat.displayTitle(hit.title, kind: hit.kind))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("[\(KFormat.mmss(hit.tStartMs))]")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let speaker = hit.speaker {
                    Text(speaker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KindBadge(kind: hit.kind)
            }
            Text(hit.snippet)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(KFormat.relativeString(hit.startedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
    }
}

struct KindBadge: View {
    let kind: String

    private var isMeeting: Bool { kind == "meeting" }

    var body: some View {
        Text(isMeeting ? "Meeting" : "Dictation")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(isMeeting ? Color.blue : Color.green)
            .background(
                Capsule().fill((isMeeting ? Color.blue : Color.green).opacity(0.13)))
    }
}
