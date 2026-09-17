import AppKit
import Combine
import ObjectiveC

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
    static let minWidth = SidebarState.minWidth
    static let maxWidth = SidebarState.maxWidth
    static let defaultWidth = SidebarState.defaultWidth

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
        editingDraft = project.displayName
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
        let state = SidebarState(isVisible: sidebarState.isVisible, expandedWidth: width)
        guard state != sidebarState else { return }
        sidebarState = state
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
            let siblings = controllers.filter { $0.project.id == controller.project.id }
            let remembered = siblings.first { $0.projectTabID == $0.project.selectedTabID }
                ?? siblings.first
            // A sibling may already have received the initial shell directory
            // while another tab still holds the earlier, incomplete metadata.
            let established = siblings.compactMap { $0.project.directory }.first
            if let pwd = established ?? remembered?.focusedSurface?.pwd,
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
