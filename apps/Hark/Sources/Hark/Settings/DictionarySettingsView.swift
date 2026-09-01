import SwiftUI

/// Dictionary tab: the user's custom vocabulary — canonical spellings the
/// speech models habitually get wrong (term "Ayesha", wrong spellings
/// ["Aisha"]). All mutations go through the Rust store's FFI methods and
/// then pipeline.reloadDictionary(), so every layer (speech recognition,
/// cleanup prompt, final spelling pass) picks the change up immediately.
struct DictionarySettingsView: View {
    let pipeline: DictationPipeline

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var newAliases = ""
    @State private var errorMessage: String?
    @State private var editing: DictionaryEntry?

    var body: some View {
        Group {
            if pipeline.store == nil {
                unavailableView
            } else {
                form
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { entry in
            DictionaryEditSheet(entry: entry) { term, aliases in
                mutate {
                    try pipeline.store?.updateDictionaryTerm(
                        id: entry.id, term: term,
                        aliases: splitAliases(aliases), enabled: entry.enabled)
                }
            }
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Dictionary unavailable")
                .font(.headline)
            Text("The local database could not be opened, so dictionary terms can't be stored. Dictation still works.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("No terms yet. Add names or jargon the transcriber keeps misspelling.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(entries, id: \.id) { entry in
                    row(for: entry)
                }
            } footer: {
                Text("Terms are fed to speech recognition, the cleanup model, and a final spelling pass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Add term") {
                TextField("Correct spelling", text: $newTerm, prompt: Text("Ayesha"))
                    .autocorrectionDisabled()
                TextField(
                    "Wrong spellings (comma-separated)", text: $newAliases,
                    prompt: Text("Aisha, Aischa")
                )
                .autocorrectionDisabled()
                HStack {
                    Button("Add") { add() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(for entry: DictionaryEntry) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { enabled in
                    mutate {
                        try pipeline.store?.updateDictionaryTerm(
                            id: entry.id, term: entry.term,
                            aliases: entry.aliases, enabled: enabled)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .fontWeight(.medium)
                    .foregroundStyle(entry.enabled ? .primary : .secondary)
                Text(entry.aliases.isEmpty
                    ? "no wrong spellings listed"
                    : entry.aliases.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = entry }

            Spacer()

            Button {
                editing = entry
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(role: .destructive) {
                mutate { try pipeline.store?.deleteDictionaryTerm(id: entry.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    // MARK: - Store plumbing

    private func reload() {
        guard let store = pipeline.store else { return }
        entries = (try? store.listDictionary()) ?? []
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        mutate {
            _ = try pipeline.store?.addDictionaryTerm(
                term: term, aliases: splitAliases(newAliases))
        }
        if errorMessage == nil {
            newTerm = ""
            newAliases = ""
        }
    }

    /// Runs a store mutation, refreshes the list, and re-informs the
    /// pipeline (all three correction layers) on success.
    private func mutate(_ operation: () throws -> Void) {
        errorMessage = nil
        do {
            try operation()
            reload()
            pipeline.reloadDictionary()
        } catch {
            errorMessage = "\(error)"
            reload()
        }
    }

    private func splitAliases(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// The generated bindings compile into this same target, so this is a
// same-module conformance (id: Int64 satisfies Identifiable directly).
extension DictionaryEntry: Identifiable {}

/// Edit sheet for one entry: term + comma-separated wrong spellings.
private struct DictionaryEditSheet: View {
    let entry: DictionaryEntry
    let save: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var aliases: String

    init(entry: DictionaryEntry, save: @escaping (String, String) -> Void) {
        self.entry = entry
        self.save = save
        _term = State(initialValue: entry.term)
        _aliases = State(initialValue: entry.aliases.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit term")
                .font(.headline)
            TextField("Correct spelling", text: $term)
                .autocorrectionDisabled()
            TextField("Wrong spellings (comma-separated)", text: $aliases)
                .autocorrectionDisabled()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(term, aliases)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
