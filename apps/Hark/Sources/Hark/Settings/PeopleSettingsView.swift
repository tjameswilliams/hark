import SwiftUI

/// People tab: everyone the user has named in a meeting. Hark recognizes
/// these people by voice in later meetings; here they can be renamed
/// (renaming onto another person merges the two) or forgotten, which takes
/// their name off every meeting and erases their voiceprints.
struct PeopleSettingsView: View {
    let pipeline: DictationPipeline
    /// Names feed the search index, so any change here needs a re-index.
    let onChange: () -> Void

    @State private var people: [PersonRecord] = []
    @State private var errorMessage: String?
    @State private var renaming: PersonRecord?
    @State private var forgetting: PersonRecord?

    var body: some View {
        Form {
            Section {
                if people.isEmpty {
                    Text("Nobody yet. After a meeting, play each voice and say who it is; they show up here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(people, id: \.id) { person in
                    row(for: person)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            } footer: {
                Text("A voiceprint is a short numeric description of how someone sounds, learned from meetings where you confirmed their name. Voiceprints stay in Hark's database on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(item: $renaming) { person in
            PersonRenameSheet(person: person) { name in
                mutate { try pipeline.store?.renamePerson(id: person.id, name: name) }
            }
        }
        .confirmationDialog(
            "Forget \(forgetting?.name ?? "this person")?",
            isPresented: Binding(
                get: { forgetting != nil },
                set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { person in
            Button("Forget", role: .destructive) {
                mutate { try pipeline.store?.forgetPerson(id: person.id) }
            }
        } message: { person in
            Text("Their name is removed from \(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s") and their voiceprints are erased. The transcripts are kept. This can't be undone.")
        }
    }

    private func row(for person: PersonRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).fontWeight(.medium)
                Text(detail(for: person))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                renaming = person
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename")

            Button(role: .destructive) {
                forgetting = person
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this person")
        }
    }

    private func detail(for person: PersonRecord) -> String {
        let meetings = "\(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s")"
        switch person.voiceprintCount {
        case 0: return "\(meetings) · not recognized by voice yet (too little speech)"
        case 1: return "\(meetings) · 1 voiceprint"
        default: return "\(meetings) · \(person.voiceprintCount) voiceprints"
        }
    }

    private func reload() {
        guard let store = pipeline.store else { return }
        people = (try? store.listPeople()) ?? []
    }

    private func mutate(_ operation: () throws -> Void) {
        errorMessage = nil
        do {
            try operation()
            onChange()
        } catch {
            errorMessage = "\(error)"
        }
        reload()
    }
}

// Same-module conformance, as for DictionaryEntry.
extension PersonRecord: Identifiable {}

private struct PersonRenameSheet: View {
    let person: PersonRecord
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(person: PersonRecord, save: @escaping (String) -> Void) {
        self.person = person
        self.save = save
        _name = State(initialValue: person.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(person.name)").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(commit)
            Text("Using another person's name merges the two.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}
