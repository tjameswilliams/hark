import SwiftUI

/// Sidebar: fixed library filters (All / Dictations / Meetings) plus the
/// projects list, with creation (sheet) and deletion (confirmed; sessions
/// revert to unassigned).
struct SidebarView: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label("All", systemImage: "tray.full")
                    .tag(SidebarItem.all)
                Label("Dictations", systemImage: "mic")
                    .tag(SidebarItem.dictations)
                Label("Meetings", systemImage: "person.2.wave.2")
                    .tag(SidebarItem.meetings)
            }
            Section("Projects") {
                ForEach(model.projects) { project in
                    HStack {
                        Label(project.name, systemImage: "folder")
                            .lineLimit(1)
                        Spacer()
                        Text("\(project.sessionCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.project(project.id))
                    .help(project.description ?? project.name)
                    .contextMenu {
                        Button("Delete Project…", role: .destructive) {
                            model.projectPendingDelete = project
                        }
                    }
                }
                Button {
                    model.showNewProjectSheet = true
                } label: {
                    Label("New Project…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $model.showNewProjectSheet) {
            NewProjectSheet(model: model)
        }
        .alert(
            "Delete “\(model.projectPendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { model.projectPendingDelete != nil },
                set: { if !$0 { model.projectPendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let project = model.projectPendingDelete {
                    model.deleteProject(project)
                }
                model.projectPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                model.projectPendingDelete = nil
            }
        } message: {
            Text("Its sessions aren't deleted — they go back to being unassigned.")
        }
    }
}

/// "+ New Project" sheet: name (required) + optional description.
struct NewProjectSheet: View {
    @Bindable var model: KnowledgeModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var descriptionText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project")
                .font(.headline)
            TextField("Name", text: $name)
            TextField("Description (optional)", text: $descriptionText)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createProject(name: name, description: descriptionText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 380)
    }
}
