import AppKit
import SwiftUI

/// Detail column: the transcript of the selected session, with a header
/// (title / date / kind), a project picker, a copy button and, for meetings,
/// the sheet for saying who each voice is.
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
        .sheet(item: $model.speakerEditing) { editing in
            SpeakerNamingSheet(editing: editing) { model.saveSpeakers(editing) }
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
            if header.kind == "meeting" {
                Button {
                    model.editSpeakersOfSelectedSession()
                } label: {
                    Label("Speakers", systemImage: "person.wave.2")
                }
                .help("Say who each voice in this meeting is")
            }
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

/// "Who spoke in this meeting?" for a meeting already in the library: the
/// same play-and-name rows as the post-meeting window.
private struct SpeakerNamingSheet: View {
    let editing: KnowledgeModel.SpeakerEditing
    let save: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var listed: [ReviewSpeaker] { editing.speakers.filter { !$0.isBrief } }

    /// Why voices can't be played, when they can't.
    private var playbackNote: String? {
        if !editing.speakers.contains(where: { $0.clip != nil }) {
            return "This meeting was recorded before Hark kept voiceprints. You can name its voices, but not play them, and Hark won't learn them from it."
        }
        if editing.audioPath == nil {
            return "The recording is no longer on disk, so these voices can't be played."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who spoke in this meeting?").font(.headline)
            if listed.isEmpty {
                Text("No voices were told apart in this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Play a voice and say who it is. Hark learns from each one you confirm and recognizes them in later meetings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(listed) { speaker in
                            SpeakerRow(
                                speaker: speaker, audioPath: editing.audioPath,
                                knownPeople: editing.knownPeople, disabled: false)
                            if speaker.id != listed.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxHeight: 360)
            }
            if let playbackNote {
                Text(playbackNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { ClipPlayer.shared.stop() }
    }
}
