import AppKit
import SwiftUI

/// Detail column: the transcript of the selected session, with a header
/// (title / date / kind), a project picker, and a copy button.
struct TranscriptPane: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        if let header = model.selectedHeader {
            TranscriptView(model: model, header: header)
        } else {
            ContentUnavailableView(
                "No Session Selected", systemImage: "bird",
                description: Text("Pick a meeting or dictation from the list, or search across everything."))
        }
    }
}

struct TranscriptView: View {
    @Bindable var model: KnowledgeModel
    let header: KnowledgeModel.SessionHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(16)
            Divider()
            if let text = model.transcriptText {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Transcript Unavailable", systemImage: "exclamationmark.triangle",
                    description: Text(model.transcriptError ?? "This session has no transcript."))
            }
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(KFormat.displayTitle(header.title, kind: header.kind))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    KindBadge(kind: header.kind)
                    if !header.startedAt.isEmpty {
                        Text(KFormat.absoluteString(header.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            projectMenu
            Button {
                copyTranscript()
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .disabled(model.transcriptText == nil)
        }
    }

    private var currentProjectName: String {
        guard let projectId = header.projectId else { return "No Project" }
        return model.projects.first(where: { $0.id == projectId })?.name ?? "No Project"
    }

    private var projectMenu: some View {
        Menu {
            Button {
                model.assignSelectedSession(to: nil)
            } label: {
                if header.projectId == nil {
                    Label("No Project", systemImage: "checkmark")
                } else {
                    Text("No Project")
                }
            }
            if !model.projects.isEmpty {
                Divider()
            }
            ForEach(model.projects) { project in
                Button {
                    model.assignSelectedSession(to: project.id)
                } label: {
                    if header.projectId == project.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        } label: {
            Label(currentProjectName, systemImage: "folder")
        }
        .fixedSize()
        .help("Assign this session to a project")
    }

    private func copyTranscript() {
        guard let text = model.transcriptText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        harkLog("knowledge: copied the transcript of session #\(header.id) to the clipboard.")
    }
}
