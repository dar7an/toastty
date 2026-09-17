import AppKit
import Combine
import ObjectiveC
import SwiftUI

/// Stable identity shared by the tabs that belong to a directory project.
///
/// A project is identified by `id`, so two projects may share the same
/// directory or display name. `directory` is the fixed directory the project
/// was created from — changing directories inside a tab never updates it.
/// `nameOverride` is a user-supplied rename; nil means the name is derived.
struct TerminalProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var directory: String?
    var nameOverride: String?
    var selectedTabID: UUID?

    /// Legacy-compatible display name. Prefer `displayName` in new code.
    var name: String {
        get { displayName }
        set { nameOverride = newValue }
    }

    /// The name shown in the UI: an explicit rename when set, otherwise the
    /// basename of the project directory, otherwise a generic fallback.
    var displayName: String {
        if let override = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return automaticName
    }

    /// The derived name without any user override: the directory basename,
    /// with root staying "/" and a generic fallback when directory is missing.
    var automaticName: String {
        if let directory, !directory.isEmpty {
            if directory == "/" { return "/" }
            let base = URL(fileURLWithPath: directory).lastPathComponent
            if !base.isEmpty { return base }
            return directory
        }
        return "Terminal"
    }

    /// The project directory with the current user's home abbreviated to `~`.
    /// Paths outside the home directory (including spaces and Unicode) pass
    /// through unchanged.
    var abbreviatedDirectory: String? {
        directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    init(
        id: UUID = UUID(),
        directory: String? = nil,
        nameOverride: String? = nil,
        selectedTabID: UUID? = nil
    ) {
        self.id = id
        self.directory = directory
        self.nameOverride = nameOverride
        self.selectedTabID = selectedTabID
    }

    /// Legacy initializer: pre-directory projects were identified by name,
    /// which is preserved as the override.
    init(id: UUID = UUID(), name: String, selectedTabID: UUID? = nil, directory: String? = nil) {
        self.init(
            id: id,
            directory: directory,
            nameOverride: name.isEmpty ? nil : name,
            selectedTabID: selectedTabID)
    }

    /// Copy with a new selected tab.
    func withSelectedTab(_ tabID: UUID?) -> TerminalProject {
        var copy = self
        copy.selectedTabID = tabID
        return copy
    }

    /// Remember the project's directory once without changing its display
    /// name. Later `cd`s must never call this: the directory is identity.
    mutating func backfillDirectory(from pwd: String?) {
        guard directory == nil, let pwd, !pwd.isEmpty else { return }
        directory = pwd
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameOverride
        case directory
        case selectedTabID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        if container.contains(.nameOverride) {
            nameOverride = try container.decodeIfPresent(String.self, forKey: .nameOverride)
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .name) {
            // Old records only carry the resolved `name`; preserve it as the
            // override so the display name survives the migration.
            nameOverride = legacy
        } else {
            nameOverride = nil
        }
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // The resolved legacy field stays encoded for older clients.
        try container.encode(displayName, forKey: .name)
        // Encoded explicitly (including null) so derived names stay
        // distinguishable from overridden ones across a round-trip.
        try container.encode(nameOverride, forKey: .nameOverride)
        try container.encode(directory, forKey: .directory)
        try container.encode(selectedTabID, forKey: .selectedTabID)
    }
}

/// TODO-tolerant helper for workstream A: uses `displayName` when available, else `name`.
func projectDisplayName(_ project: TerminalProject) -> String {
    project.displayName
}

/// Collapsible-sidebar state shared by every window in one AppKit tab group.
/// Stored on ``TabSidebarModel`` (the per-group source of truth) and mirrored
/// onto member controllers for undo/restoration. Optional in restorable state
/// so archives written before the sidebar collapse feature decode as nil.
struct SidebarState: Codable, Equatable {
    /// Whether the sidebar split item is expanded. Collapse reallocates
    /// space to the terminal content item; the outer window frame is kept.
    var isVisible: Bool

    /// The divider width restored on expansion. Always clamped to
    /// `TabSidebarModel.minWidth...maxWidth`.
    var expandedWidth: CGFloat
}

extension NSWindowTabGroup {
    private static var tabSidebarModelKey: UInt8 = 0

    /// AppKit carries the terminal windows; the model partitions them into projects.
    var tabSidebarModel: TabSidebarModel {
        if let model = objc_getAssociatedObject(self, &Self.tabSidebarModelKey) as? TabSidebarModel {
            return model
        }

        let model = TabSidebarModel(tabGroup: self)
        objc_setAssociatedObject(
            self, &Self.tabSidebarModelKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return model
    }
}

/// Shared project and tab state for one visible window. Mutated on the main queue.
final class TabSidebarModel: ObservableObject {
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 220

    private static let widthDefaultsKey = "TabSidebarWidth"

    struct Row: Identifiable {
        let window: NSWindow
        var id: ObjectIdentifier { ObjectIdentifier(window) }
        var project: TerminalProject
        var title: String = ""
        var pwd: String?
        var tabColor: TerminalTabColor = .none
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selection: ObjectIdentifier?
    @Published private(set) var selectedProjectID: UUID?
    private var selectedTabs: [UUID: ObjectIdentifier] = [:]

    /// Inline rename editor state. Lives on the shared model so an AppKit window
    /// switch during double-click doesn't destroy the editor.
    @Published var editingProjectID: UUID?
    @Published var editingDraft: String = ""
    private var lastProjectClick: (id: UUID, timestamp: TimeInterval)?

    var projects: [TerminalProject] {
        var seen = Set<UUID>()
        return rows.compactMap { seen.insert($0.project.id).inserted ? $0.project : nil }
    }

    var visibleTabs: [Row] { rows.filter { $0.project.id == selectedProjectID } }

    func selectProject(_ id: UUID?) {
        guard let id else { return }
        let tabs = rows.filter { $0.project.id == id }
        let remembered = tabs.first { $0.id == selectedTabs[id] }
            ?? tabs.first { row in
                guard let controller = row.window.windowController as? TerminalController else { return false }
                return controller.projectTabID == controller.project.selectedTabID
            }
        select(remembered?.id ?? tabs.first?.id)
    }

    func refresh() { rebuildRows() }

    // MARK: Rename

    /// Keep click history across the native window switch on the first click.
    /// Each window has a different SwiftUI row, so a row-local double-click
    /// recognizer cannot reliably recognize clicks on an inactive project.
    func clickProject(_ id: UUID, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard editingProjectID != id else { return }
        if let previous = lastProjectClick,
           previous.id == id,
           timestamp >= previous.timestamp,
           timestamp - previous.timestamp <= NSEvent.doubleClickInterval {
            lastProjectClick = nil
            beginRename(projectID: id)
        } else {
            lastProjectClick = (id, timestamp)
            selectProject(id)
        }
    }

    func beginRename(projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        lastProjectClick = nil
        selectProject(projectID)
        editingProjectID = projectID
        editingDraft = projectDisplayName(project)
    }

    func commitRename() {
        guard let id = editingProjectID else { return }
        let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelRename()
            return
        }
        for window in tabGroup?.windows ?? [] {
            guard let controller = window.windowController as? TerminalController,
                  controller.project.id == id else { continue }
            if trimmed == controller.project.automaticName {
                // Renaming to the derived name is the same as no override.
                controller.project.nameOverride = nil
            } else {
                controller.project.nameOverride = trimmed
            }
        }
        editingProjectID = nil
        editingDraft = ""
        refresh()
        restoreTerminalFocus()
    }

    func cancelRename() {
        guard editingProjectID != nil else { return }
        editingProjectID = nil
        editingDraft = ""
        restoreTerminalFocus()
    }

    /// Abbreviated directory for a project: fixed creation dir, else first tab's pwd.
    func directory(for project: TerminalProject) -> String? {
        if let dir = project.abbreviatedDirectory { return dir }
        return rows.first(where: { $0.project.id == project.id })?.pwd
    }

    private func restoreTerminalFocus() {
        guard let window = tabGroup?.selectedWindow,
              let controller = window.windowController as? TerminalController else { return }
        window.makeFirstResponder(controller.focusedSurface)
    }

    /// Source of truth for sidebar visibility and width. New independent
    /// windows start expanded with the saved width; new tabs inherit their
    /// group's state; moved tabs adopt the destination group's state.
    @Published var sidebarState: SidebarState {
        didSet {
            if sidebarState.expandedWidth != oldValue.expandedWidth {
                UserDefaults.ghostty.set(sidebarState.expandedWidth, forKey: Self.widthDefaultsKey)
            }
            if sidebarState != oldValue {
                mirrorSidebarStateToMembers()
            }
        }
    }

    /// The expanded (restored) sidebar width. The native split divider owns
    /// resizing now; this stays as the single value sizing math reads.
    var width: CGFloat {
        get { sidebarState.expandedWidth }
        set { setExpandedWidth(newValue) }
    }

    /// Collapse or expand the sidebar, preserving the restored width.
    func setVisible(_ visible: Bool) {
        guard sidebarState.isVisible != visible else { return }
        sidebarState.isVisible = visible
    }

    /// Record a divider width, clamped to the 160–320pt range.
    func setExpandedWidth(_ width: CGFloat) {
        let clamped = min(Self.maxWidth, max(Self.minWidth, width))
        guard clamped != sidebarState.expandedWidth else { return }
        sidebarState.expandedWidth = clamped
    }

    /// Mirrors group sidebar state onto member controllers so undo and state
    /// restoration can capture it as plain data. Plain assignment cannot loop.
    private func mirrorSidebarStateToMembers() {
        for window in tabGroup?.windows ?? [] {
            (window.windowController as? TerminalController)?.sidebarState = sidebarState
        }
    }

    private weak var tabGroup: NSWindowTabGroup?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var pwdCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    init(tabGroup: NSWindowTabGroup) {
        self.tabGroup = tabGroup

        // New independent windows start expanded with the saved width.
        let persistedWidth = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        let initialWidth = persistedWidth > 0
            ? min(Self.maxWidth, max(Self.minWidth, persistedWidth))
            : Self.defaultWidth
        self.sidebarState = SidebarState(isVisible: true, expandedWidth: initialWidth)

        // `.initial` triggers the first row build. Rebuilds are deferred one
        // main-queue turn because replacing an observation inside its own
        // callback leaves the observed object retained by AppKit (see
        // TransparentTitlebarTerminalWindow.setupKVO for the same pattern).
        let windows = tabGroup.observe(\.windows, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.rebuildRows()
            }
        }

        // Keep keyboard and native tab-bar changes reflected in the sidebar.
        let selected = tabGroup.observe(\.selectedWindow, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.syncSelection()
            }
        }

        let tabBar = tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.suppressNativeTabBar() }
        }
        groupObservations = [windows, selected, tabBar]
    }

    deinit {
        groupObservations.forEach { $0.invalidate() }
        invalidateTabObservations()
    }

    // MARK: Selection

    func select(_ id: ObjectIdentifier?) {
        guard let id,
              let tabGroup,
              let row = rows.first(where: { $0.id == id }),
              tabGroup.windows.contains(row.window) else { return }

        if tabGroup.selectedWindow != row.window {
            tabGroup.selectedWindow = row.window
        }
        syncSelection()

        // Return typing focus to the terminal so the list doesn't keep it.
        let controller = row.window.windowController as? TerminalController
        row.window.makeFirstResponder(controller?.focusedSurface)
    }

    // MARK: Private

    private func rebuildRows() {
        guard let tabGroup else { return }
        invalidateTabObservations()

        // Old saved windows have no project identity. Keep their restored native
        // group together as AppKit assembles it over successive runloop turns.
        let controllers = tabGroup.windows.compactMap { $0.windowController as? TerminalController }
        if let legacyProject = controllers.first(where: { $0.projectNeedsMigration })?.project {
            for controller in controllers where controller.projectNeedsMigration && controller.project.id != legacyProject.id {
                controller.project = legacyProject
            }
        }

        // Restored windows from before project directories carry no directory.
        // Remember each project's directory once from its remembered selected
        // tab without changing the (possibly legacy) display name. Later `cd`s
        // never update it: the directory is identity, not live state.
        var backfilledProjects = Set<UUID>()
        for controller in controllers where backfilledProjects.insert(controller.project.id).inserted {
            guard controller.project.directory == nil else { continue }
            let siblings = controllers.filter { $0.project.id == controller.project.id }
            let remembered = siblings.first { $0.projectTabID == $0.project.selectedTabID }
                ?? siblings.first
            if let pwd = remembered?.focusedSurface?.pwd,
               TerminalController.isPlausibleProjectDirectory(pwd) {
                for sibling in siblings {
                    sibling.project.backfillDirectory(from: pwd)
                }
            }
        }

        rows = tabGroup.windows.map { window in
            observe(window: window)
            let pwd = (window.windowController as? TerminalController)?.focusedSurface?.pwd
            return Row(
                window: window,
                project: (window.windowController as? TerminalController)?.project ?? TerminalProject(),
                title: window.title,
                pwd: pwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
                tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
        }

        mirrorSidebarStateToMembers()
        syncSelection()
    }

    private func observe(window: NSWindow) {
        let id = ObjectIdentifier(window)

        titleObservations[id] = window.observe(\.title, options: [.new]) { [weak self] win, _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateTitle(for: win)
            }
        }

        // The row's working directory follows the tab's focused surface, so
        // split focus changes update it as well.
        if let controller = window.windowController as? TerminalController {
            pwdCancellables[id] = controller.$focusedSurface
                .map { surface -> AnyPublisher<String?, Never> in
                    guard let surface else {
                        return Just<String?>(nil).eraseToAnyPublisher()
                    }
                    return surface.$pwd.eraseToAnyPublisher()
                }
                .switchToLatest()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] pwd in
                    self?.updatePwd(pwd, for: window)
                }
        }

        // Each tab is its own window, so any tab switch (mouse or keyboard)
        // makes one of these fire.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.syncSelection()
            }
            notificationTokens.append(token)
        }

        // `tabColor` is not KVO compliant so it posts a notification instead.
        let colorToken = NotificationCenter.default.addObserver(
            forName: TerminalWindow.tabColorDidChangeNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.updateTabColor(for: window)
        }
        notificationTokens.append(colorToken)
    }

    private func updateTitle(for window: NSWindow) {
        guard let index = rows.firstIndex(where: { $0.window == window }) else { return }
        rows[index].title = window.title
    }

    private func updateTabColor(for window: NSWindow) {
        guard let index = rows.firstIndex(where: { $0.window == window }) else { return }
        rows[index].tabColor = (window as? TerminalWindow)?.tabColor ?? .none
    }

    private func updatePwd(_ pwd: String?, for window: NSWindow) {
        guard let index = rows.firstIndex(where: { $0.window == window }) else { return }
        rows[index].pwd = pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    private func syncSelection() {
        selection = tabGroup?.selectedWindow.map { ObjectIdentifier($0) }
        if let row = rows.first(where: { $0.id == selection }) {
            selectedProjectID = row.project.id
            selectedTabs[row.project.id] = row.id
            if let selected = row.window.windowController as? TerminalController {
                for tab in rows where tab.project.id == row.project.id {
                    guard let controller = tab.window.windowController as? TerminalController,
                          controller.project.selectedTabID != selected.projectTabID else { continue }
                    controller.project.selectedTabID = selected.projectTabID
                }
            }
        }
        suppressNativeTabBar()
    }

    private func suppressNativeTabBar() {
        for window in tabGroup?.windows ?? [] {
            (window as? TerminalWindow)?.hideProjectNativeTabBar()
        }
    }

    private func invalidateTabObservations() {
        titleObservations.values.forEach { $0.invalidate() }
        titleObservations.removeAll()
        pwdCancellables.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }
}

/// Project list content for the native sidebar split item (workstream C).
///
/// Width comes from the `NSSplitViewItem` divider (160–320pt) and the top of
/// the sidebar extends under the native unified toolbar, so the 50pt traffic
/// lights spacer, the project-title header, the 40pt tab row, and the SwiftUI
/// resize handle that `ProjectWorkspaceView` used are gone. The tab strip
/// lives in `ProjectTabStripView`, hosted by the toolbar instead.
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
                // Only the visible window owns the editor and its focus.
                // Hidden tabs share this model but must not create competing
                // focused fields or commit the draft when they lose focus.
                if model.editingProjectID == project.id,
                   controller.window.map(ObjectIdentifier.init) == model.selection {
                    ProjectRenameField(model: model, projectID: project.id)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(projectDisplayName(project))
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
            let name = projectDisplayName(project)
            if let directory = model.directory(for: project) {
                return "\(name)\n\(directory)"
            }
            return name
        }

        private func projectAccessibilityLabel(_ project: TerminalProject) -> String {
            let name = projectDisplayName(project)
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
                    .lineLimit(1)
                    .focused($focused)
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .onAppear {
                        focused = true
                        // Select the existing name so typing replaces it.
                        DispatchQueue.main.async {
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                        }
                    }
                    .onChange(of: focused) { isFocused in
                        // Clicking elsewhere commits a valid name, cancels an invalid one.
                        if !isFocused, model.editingProjectID == projectID {
                            model.commitRename()
                        }
                    }
            }
        }
}
