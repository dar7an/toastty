import SwiftUI

/// Project navigation and inline renaming in the native sidebar.
struct ProjectSidebarListView: View {
    @ObservedObject var model: TabSidebarModel
    let controller: TerminalController

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedProjectID }, set: { model.selectProject($0) })) {
                ForEach(model.projects) { project in
                    projectRow(project)
                        .tag(project.id)
                        .help(projectHelp(project))
                        .accessibilityLabel(projectAccessibilityLabel(project))
                        .contextMenu {
                            Button("Rename Project…") { model.beginRename(projectID: project.id) }
                            Button("Close Project") { projectController(project)?.closeProject() }
                            Divider()
                            Button("New Project") { projectController(project)?.newProject(nil) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)
            .contextMenu {
                Button("New Project") { controller.newProject(nil) }
            }
        }
        // Extend the sidebar's one material through the traffic-light and
        // toolbar region, while the list itself respects the safe area.
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects")
    }

    private func projectController(_ project: TerminalProject) -> TerminalController? {
        model.selectProject(project.id)
        return model.rows.first(where: { $0.id == model.selection })?.window.windowController as? TerminalController
    }

    private func projectRow(_ project: TerminalProject) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Only the visible window owns the editor and its focus.
            // Hidden tabs share this model but must not create competing
            // focused fields or commit the draft when they lose focus.
            if model.editingProjectID == project.id,
               controller.window.map(ObjectIdentifier.init) == model.selection {
                ProjectRenameField(model: model, projectID: project.id)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let directory = model.directory(for: project) {
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            model.clickProject(project.id)
        }
    }

    private func projectHelp(_ project: TerminalProject) -> String {
        let name = project.displayName
        if let directory = model.directory(for: project) {
            return "\(name)\n\(directory)"
        }
        return name
    }

    private func projectAccessibilityLabel(_ project: TerminalProject) -> String {
        let name = project.displayName
        if let directory = model.directory(for: project) {
            return "\(name), \(directory)"
        }
        return name
    }

    private struct ProjectRenameField: View {
        @ObservedObject var model: TabSidebarModel
        let projectID: UUID
        @FocusState private var focused: Bool

        var body: some View {
            TextField("", text: $model.editingDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project name")
                .lineLimit(1)
                .focused($focused)
                .onSubmit { model.commitRename() }
                .onExitCommand { model.cancelRename() }
                .onAppear {
                    focused = true
                    // Select the existing name so typing replaces it.
                    DispatchQueue.main.async {
                        selectNameIfEditing()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        selectNameIfEditing()
                    }
                }
                .onChange(of: focused) { isFocused in
                    // Clicking elsewhere commits a valid name, cancels an invalid one.
                    if !isFocused, model.editingProjectID == projectID {
                        model.commitRename()
                    }
                }
        }

        private func selectNameIfEditing() {
            guard focused, model.editingProjectID == projectID,
                  let row = model.rows.first(where: { $0.id == model.selection }),
                  row.project.id == projectID, row.window.isKeyWindow,
                  let editor = row.window.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField,
                  field.currentEditor() === editor else { return }
            editor.selectAll(nil)
        }
    }
}
