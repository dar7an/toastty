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
    var emoji: String?
    var color: TerminalTabColor
    /// User-defined sidebar position, independent of the project's tab order.
    /// Older projects keep their existing order until the first rearrangement.
    var sidebarOrder: Int?

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
        selectedTabID: UUID? = nil,
        emoji: String? = nil,
        color: TerminalTabColor = .none
    ) {
        self.id = id
        self.directory = directory
        self.nameOverride = nameOverride
        self.selectedTabID = selectedTabID
        self.emoji = Self.normalizedEmoji(emoji)
        self.color = color
    }

    /// Legacy initializer: pre-directory projects were identified by name,
    /// which is preserved as the override.
    init(
        id: UUID = UUID(),
        name: String,
        selectedTabID: UUID? = nil,
        directory: String? = nil,
        emoji: String? = nil,
        color: TerminalTabColor = .none
    ) {
        self.init(
            id: id,
            directory: directory,
            nameOverride: name.isEmpty ? nil : name,
            selectedTabID: selectedTabID,
            emoji: emoji,
            color: color)
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

    /// Returns one emoji grapheme cluster, or nil for the default icon.
    /// Character Viewer can insert composed sequences such as skin-tone and
    /// ZWJ emoji, so validation must use grapheme count rather than scalar or
    /// UTF-16 length.
    static func normalizedEmoji(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // `isEmoji` alone accepts ASCII digits and symbols like "#": they
        // carry the Emoji property but default to text presentation. Require
        // a scalar that renders as emoji, either by default or via U+FE0F.
        guard candidate.count == 1,
              candidate.unicodeScalars.contains(where: { $0.properties.isEmoji }),
              candidate.unicodeScalars.contains(where: {
                  $0.properties.isEmojiPresentation || $0.value == 0xFE0F
              }) else {
            return nil
        }
        return candidate.precomposedStringWithCanonicalMapping
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameOverride
        case directory
        case selectedTabID
        case emoji
        case color
        case sidebarOrder
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
        emoji = Self.normalizedEmoji(try container.decodeIfPresent(String.self, forKey: .emoji))
        sidebarOrder = try container.decodeIfPresent(Int.self, forKey: .sidebarOrder)
        // An unknown stored value (e.g. a color added by a newer build) must
        // not fail the whole project's decode: raw enum decoding throws
        // before the nil fallback, so decode the raw value lossily.
        if let rawColor = try container.decodeIfPresent(Int.self, forKey: .color) {
            color = TerminalTabColor(rawValue: rawColor) ?? .none
        } else {
            color = .none
        }
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
        try container.encode(emoji, forKey: .emoji)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(sidebarOrder, forKey: .sidebarOrder)
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
        // Seed before the first SwiftUI render. Later KVO rebuilds remain
        // deferred so they never replace observations inside their callback.
        model.refresh()
        return model
    }
}

extension NSWindow {
    private static var standaloneTabSidebarModelKey: UInt8 = 0

    /// Project chrome also exists after AppKit tears a tab out of its group.
    var projectSidebarModel: TabSidebarModel {
        tabGroup?.tabSidebarModel ?? standaloneTabSidebarModel
    }

    var standaloneTabSidebarModel: TabSidebarModel {
        if let model = objc_getAssociatedObject(
            self,
            &Self.standaloneTabSidebarModelKey
        ) as? TabSidebarModel {
            return model
        }

        let model = TabSidebarModel(window: self)
        objc_setAssociatedObject(
            self,
            &Self.standaloneTabSidebarModelKey,
            model,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        model.refresh()
        return model
    }
}

/// Shared project and tab state for one visible window. Mutated on the main queue.
final class TabSidebarModel: ObservableObject {
    /// Prevent project drags from rearranging a different window group.
    let dragID = UUID()
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
    /// Drag feedback must not activate another native tab window and destroy
    /// the source view. Restore the active project's highlight on drop/cancel.
    @Published var draggingProjectID: UUID?
    var highlightedProjectID: UUID? { draggingProjectID ?? selectedProjectID }
    /// A lifted tab still belongs to this group until its drop commits.
    /// Hide only its rail cell; cancelling must not reconstruct terminals.
    @Published var liftedTabID: ObjectIdentifier?
    private var selectedTabs: [UUID: ObjectIdentifier] = [:]

    /// Inline rename editor state. Lives on the shared model so an AppKit window
    /// switch during double-click doesn't destroy the editor.
    @Published var editingProjectID: UUID?
    @Published var editingDraft: String = ""
    /// Emoji editor state is also shared because the sidebar row can be rebuilt
    /// while the Character Viewer is open.
    @Published var editingProjectEmojiID: UUID?
    @Published var editingProjectEmojiDraft: String = ""
    private var lastProjectClick: (id: UUID, timestamp: TimeInterval)?
    private var lastTabClick: (id: ObjectIdentifier, timestamp: TimeInterval)?

    /// Native tab selection swaps hosting views between the two clicks.
    /// Keep the click history on their shared model, as with project rename.
    func recordTabClick(_ id: ObjectIdentifier, timestamp: TimeInterval) -> Bool {
        guard let previous = lastTabClick, previous.id == id,
              timestamp >= previous.timestamp,
              timestamp - previous.timestamp <= NSEvent.doubleClickInterval else {
            lastTabClick = (id, timestamp)
            return false
        }
        lastTabClick = nil
        return true
    }

    func cancelTabClick() { lastTabClick = nil }
    func cancelProjectClick() { lastProjectClick = nil }

    var projects: [TerminalProject] {
        var seen = Set<UUID>()
        let unique = rows.compactMap { seen.insert($0.project.id).inserted ? $0.project : nil }
        return unique.enumerated().sorted { lhs, rhs in
            let left = lhs.element.sidebarOrder ?? Int.max
            let right = rhs.element.sidebarOrder ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    var visibleTabs: [Row] { rows.filter { $0.project.id == selectedProjectID } }
    var railTabs: [Row] { visibleTabs.filter { $0.id != liftedTabID } }

    /// Native List movement changes only project metadata. Keeping AppKit's
    /// windows in place preserves tab order, remembered selection, and shells.
    func moveProjects(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ordered = projects.map(\.id)
        guard !offsets.isEmpty, offsets.allSatisfy(ordered.indices.contains),
              (0...ordered.count).contains(destination),
              editingProjectID == nil, editingProjectEmojiID == nil else { return }
        let previous = ordered
        ordered.move(fromOffsets: offsets, toOffset: destination)
        guard ordered != previous else { return }
        lastProjectClick = nil
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        for window in windows {
            guard let controller = window.windowController as? TerminalController,
                  let position = positions[controller.project.id],
                  controller.project.sidebarOrder != position else { continue }
            // Every member carries the position through window restoration,
            // tab creation, and closing/reopening a project's selected tab.
            controller.project.sidebarOrder = position
        }
        refreshProjectMetadata()
    }

    func canMoveProject(_ id: UUID, by offset: Int) -> Bool {
        let ordered = projects
        guard editingProjectID == nil, editingProjectEmojiID == nil,
              let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
        return ordered.indices.contains(index + offset)
    }

    func moveProject(_ id: UUID, by offset: Int) {
        guard canMoveProject(id, by: offset),
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        moveProjects(fromOffsets: IndexSet(integer: index), toOffset: index + offset + (offset > 0 ? 1 : 0))
    }

    /// Selects a project's remembered tab, optionally returning focus to it.
    func selectProject(_ id: UUID?, stealFocus: Bool = true) {
        guard let id else { return }
        let tabs = rows.filter { $0.project.id == id }
        let remembered = restoreTargetRow(for: id)
        select(remembered?.id ?? tabs.first?.id, stealFocus: stealFocus)
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
        if editingProjectEmojiID != nil { cancelProjectEmojiEdit() }
        lastProjectClick = nil
        selectProject(projectID)
        editingProjectID = projectID
        editingDraft = projectDisplayName(project)
    }

    /// Commits the inline project name, clearing overrides for blank defaults.
    func commitRename() {
        guard let id = editingProjectID else { return }
        let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank restores the default name, matching tab rename behavior
        // (BaseTerminalController.promptTabTitle clears the override).
        let newOverride: String? = if trimmed.isEmpty {
            nil
        } else {
            trimmed
        }
        for window in windows {
            guard let controller = window.windowController as? TerminalController,
                  controller.project.id == id else { continue }
            if newOverride == nil || newOverride == controller.project.automaticName {
                // Blank or renaming to the derived name is the same as no override.
                controller.project.nameOverride = nil
            } else {
                controller.project.nameOverride = newOverride
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

    // MARK: Project Appearance

    /// Opens the emoji editor for a project and makes that project visible.
    /// The draft is kept on the shared model so row rebuilds cannot discard it.
    func beginProjectEmojiEdit(projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if editingProjectID != nil { commitRename() }
        if editingProjectEmojiID != nil { cancelProjectEmojiEdit() }
        selectProject(projectID)
        editingProjectEmojiID = projectID
        editingProjectEmojiDraft = ""
    }

    /// Commits a valid emoji draft. Empty input restores the default folder
    /// icon; invalid input is left in place so the editor can show the error.
    func commitProjectEmojiEdit() {
        guard let projectID = editingProjectEmojiID else { return }
        let trimmed = editingProjectEmojiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if trimmed.isEmpty {
            normalized = nil
        } else if let value = TerminalProject.normalizedEmoji(trimmed) {
            normalized = value
        } else {
            return
        }

        updateProject(projectID) { project in
            project.emoji = normalized
        }
        editingProjectEmojiID = nil
        editingProjectEmojiDraft = ""
        restoreTerminalFocus()
    }

    func cancelProjectEmojiEdit() {
        guard editingProjectEmojiID != nil else { return }
        editingProjectEmojiID = nil
        editingProjectEmojiDraft = ""
        restoreTerminalFocus()
    }

    /// Project color uses the same palette as tab color, but is copied to all
    /// tabs belonging to this project rather than to one terminal window.
    func setProjectColor(_ color: TerminalTabColor, for projectID: UUID) {
        updateProject(projectID) { project in
            project.color = color
        }
    }

    func resetProjectAppearance(for projectID: UUID) {
        updateProject(projectID) { project in
            project.emoji = nil
            project.color = .none
        }
    }

    func resetProjectEmoji(for projectID: UUID) {
        updateProject(projectID) { $0.emoji = nil }
    }

    /// Abbreviated directory for a project: the live pwd of its selected
    /// tab's focused surface, else any tab's live pwd, else the fixed
    /// creation directory for projects whose shells have not reported yet.
    /// The stored `project.directory` stays the identity anchor — this only
    /// chooses which path the row displays.
    func directory(for project: TerminalProject) -> String? {
        let tabs = rows.filter { $0.project.id == project.id }
        // Resolve the tab the project would restore to, matching
        // `selectProject`: remembered selection, then `selectedTabID`.
        let selected = restoreTargetRow(for: project.id)
        return selected?.pwd
            ?? tabs.first(where: { $0.pwd != nil })?.pwd
            ?? project.abbreviatedDirectory
    }

    /// The tab a project would restore to: the remembered selection, else
    /// the controller-marked selected tab. Shared by selection, display,
    /// and context-menu resolution so the three can never disagree.
    func restoreTargetRow(for projectID: UUID) -> Row? {
        let tabs = rows.filter { $0.project.id == projectID }
        return tabs.first { $0.id == selectedTabs[projectID] }
            ?? tabs.first { row in
                guard let controller = row.window.windowController as? TerminalController else { return false }
                return controller.projectTabID == controller.project.selectedTabID
            }
    }

    private func restoreTerminalFocus() {
        guard let window = selectedWindow,
              let controller = window.windowController as? TerminalController else { return }
        window.makeFirstResponder(controller.focusedSurface)
    }

    /// Applies one project metadata change to every tab in the project. The
    /// model's rows are snapshots, so refresh once after the batch assignment.
    private func updateProject(
        _ projectID: UUID,
        _ update: (inout TerminalProject) -> Void
    ) {
        var changed = false
        for window in windows {
            guard let controller = window.windowController as? TerminalController,
                  controller.project.id == projectID else { continue }
            var project = controller.project
            let previous = project
            update(&project)
            guard project != previous else { continue }
            controller.project = project
            changed = true
        }
        if changed { refreshProjectMetadata() }
    }

    /// Metadata edits do not change group membership. Keep the existing
    /// window and terminal observations instead of rebuilding them all.
    private func refreshProjectMetadata() {
        rows = rows.map { row in
            var row = row
            if let controller = row.window.windowController as? TerminalController {
                row.project = controller.project
            }
            return row
        }
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
        for window in windows {
            (window.windowController as? TerminalController)?.sidebarState = sidebarState
        }
    }

    private weak var tabGroup: NSWindowTabGroup?
    private weak var standaloneWindow: NSWindow?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var pwdCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    init(tabGroup: NSWindowTabGroup) {
        self.tabGroup = tabGroup
        self.standaloneWindow = nil

        // New independent windows start expanded with the saved width.
        let persistedWidth = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        let initialWidth = persistedWidth > 0
            ? min(Self.maxWidth, max(Self.minWidth, persistedWidth))
            : Self.defaultWidth
        let inherited = (tabGroup.selectedWindow?.windowController as? TerminalController)?.sidebarState
            ?? tabGroup.windows.compactMap { ($0.windowController as? TerminalController)?.sidebarState }.first
        self.sidebarState = inherited ?? SidebarState(isVisible: true, expandedWidth: initialWidth)

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

    init(window: NSWindow) {
        self.tabGroup = nil
        self.standaloneWindow = window

        let persistedWidth = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        let initialWidth = persistedWidth > 0
            ? min(Self.maxWidth, max(Self.minWidth, persistedWidth))
            : Self.defaultWidth
        self.sidebarState = (window.windowController as? TerminalController)?.sidebarState
            ?? SidebarState(isVisible: true, expandedWidth: initialWidth)
    }

    deinit {
        groupObservations.forEach { $0.invalidate() }
        invalidateTabObservations()
    }

    // MARK: Selection

    /// Selects a sidebar row and optionally returns keyboard focus to its terminal.
    func select(_ id: ObjectIdentifier?, stealFocus: Bool = true) {
        guard let id,
              let row = rows.first(where: { $0.id == id }),
              windows.contains(row.window) else { return }

        if let tabGroup, tabGroup.selectedWindow != row.window {
            tabGroup.selectedWindow = row.window
        } else if tabGroup == nil {
            row.window.makeKey()
        }
        syncSelection()

        // Keyboard navigation must not yank focus after the first step:
        // sidebar click still focuses the terminal, but arrow-key nav keeps
        // focus in the list so repeated presses keep working.
        guard stealFocus else { return }
        if NSApp.currentEvent?.type == .keyDown { return }
        if let firstResponder = row.window.firstResponder, firstResponder != row.window {
            // If focus is already in a text field (rename editor) or another
            // control, don't steal it back to the terminal.
            if firstResponder is NSTextView || firstResponder is NSTextField { return }
        }

        // Return typing focus to the terminal so the list doesn't keep it.
        let controller = row.window.windowController as? TerminalController
        row.window.makeFirstResponder(controller?.focusedSurface)
    }

    // MARK: Private

    private func rebuildRows() {
        invalidateTabObservations()

        // Old saved windows have no project identity. Keep their restored native
        // group together as AppKit assembles it over successive runloop turns.
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
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

        rows = windows.map { window in
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
        let currentSelection = selectedWindow.map { ObjectIdentifier($0) }
        if selection != currentSelection { selection = currentSelection }
        if let row = rows.first(where: { $0.id == selection }) {
            if selectedProjectID != row.project.id { selectedProjectID = row.project.id }
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
        for window in windows {
            (window as? TerminalWindow)?.hideProjectNativeTabBar()
        }
    }

    private var windows: [NSWindow] {
        if let tabGroup { return tabGroup.windows }
        return standaloneWindow.map { [$0] } ?? []
    }

    private var selectedWindow: NSWindow? {
        tabGroup?.selectedWindow ?? standaloneWindow
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

    /// Renders the project list and its persistent new-project control.
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.highlightedProjectID }, set: {
                guard model.draggingProjectID == nil, $0 != model.selectedProjectID else { return }
                model.selectProject($0)
            })) {
                ForEach(model.projects) { project in
                    projectRow(project)
                        .tag(project.id)
                        .overlay(ProjectSidebarRowInteraction(
                            model: model, projectID: project.id,
                            isEditing: model.editingProjectID != nil || model.editingProjectEmojiID != nil))
                        .help(projectHelp(project))
                        .accessibilityLabel(projectAccessibilityLabel(project))
                        .background(ProjectSidebarContextMenu {
                            makeProjectContextMenu(project: project, model: model)
                        })
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { projectController(project)?.closeProject() } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete Project")
                            .help("Remove this project from Toastty")
                        }
                        .accessibilityActions {
                            Button("Rename Project") { model.beginRename(projectID: project.id) }
                            Button("Change Emoji") { model.beginProjectEmojiEdit(projectID: project.id) }
                            Button("Reset Emoji") { model.resetProjectEmoji(for: project.id) }
                            Button("Reset Project Appearance") { model.resetProjectAppearance(for: project.id) }
                            if model.canMoveProject(project.id, by: -1) {
                                Button("Move Project Up") { model.moveProject(project.id, by: -1) }
                            }
                            if model.canMoveProject(project.id, by: 1) {
                                Button("Move Project Down") { model.moveProject(project.id, by: 1) }
                            }
                            ForEach(TerminalTabColor.allCases, id: \.rawValue) { color in
                                Button("Project Color: \(color.localizedName)") {
                                    model.setProjectColor(color, for: project.id)
                                }
                            }
                            Button("Delete Project") { projectController(project)?.closeProject() }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)
            .onDeleteCommand {
                if let project = model.projects.first(where: { $0.id == model.selectedProjectID }) {
                    projectController(project)?.closeProject()
                }
            }
            .contextMenu {
                Button("New Project") { controller.newProject(nil) }
            }
        }
        // Extend the sidebar's one material through the traffic-light and
        // toolbar region, while the list itself respects the safe area.
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
        .background(ProjectSidebarEmptyClickGuard(model: model))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects")
    }

        /// Resolves the controller for a project without changing selection.
        private func projectController(_ project: TerminalProject) -> TerminalController? {
            // Resolve the clicked project without touching global selection,
            // using the same restore target as selection and display.
            let row = model.restoreTargetRow(for: project.id)
                ?? model.rows.first(where: { $0.project.id == project.id })
            return row?.window.windowController as? TerminalController
        }

        private func projectRow(_ project: TerminalProject) -> some View {
            HStack(spacing: 8) {
                ProjectSidebarIconView(project: project)
                    .popover(
                        isPresented: Binding(
                            get: {
                                model.editingProjectEmojiID == project.id &&
                                    controller.window.map(ObjectIdentifier.init) == model.selection
                            },
                            set: { if !$0 { model.cancelProjectEmojiEdit() } }
                        ),
                        arrowEdge: .leading
                    ) {
                        ProjectEmojiPicker { emoji in
                            guard model.editingProjectEmojiID == project.id else { return }
                            model.editingProjectEmojiDraft = emoji
                            model.commitProjectEmojiEdit()
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    // Reserve the editor's height even when showing the label.
                    // Keep the directory visible throughout rename.
                    Group {
                        if model.editingProjectID == project.id,
                           controller.window.map(ObjectIdentifier.init) == model.selection {
                            ProjectRenameField(model: model, projectID: project.id)
                        } else {
                            Text(projectDisplayName(project))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(height: 22, alignment: .leading)
                    if let directory = model.directory(for: project) {
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }

        private func projectHelp(_ project: TerminalProject) -> String {
            let name = projectDisplayName(project)
            if let directory = model.directory(for: project) {
                return "\(name)\n\(directory)"
            }
            return name
        }

        private func projectAccessibilityLabel(_ project: TerminalProject) -> String {
            var parts = [projectDisplayName(project)]
            if let emoji = project.emoji {
                parts.append("Icon \(emoji)")
            }
            if project.color != .none {
                parts.append("Color \(project.color.localizedName)")
            }
            if let directory = model.directory(for: project) {
                parts.append(directory)
            }
            return parts.joined(separator: ", ")
        }

        private struct ProjectSidebarIconView: View {
            let project: TerminalProject

            var body: some View {
                Group {
                    if let emoji = project.emoji {
                        Text(emoji)
                            .font(.system(size: 16))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        if #available(macOS 14.0, *) {
                            ProjectSidebarFolderIcon(color: project.color)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .frame(width: 20, height: 20, alignment: .center)
                .accessibilityHidden(true)
            }
        }

        private struct ProjectRenameField: View {
            @ObservedObject var model: TabSidebarModel
            let projectID: UUID
            @FocusState private var focused: Bool

            var body: some View {
                TextField("Project name", text: $model.editingDraft, prompt: Text("Leave blank to restore the default"))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .focused($focused)
                    .help("Leave blank to restore the default project name")
                    .accessibilityLabel("Rename project")
                    .accessibilityHint("Leave blank to restore the default project name")
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .onAppear {
                        // Wait for the field to be attached and for the command
                        // palette's query field to leave the responder chain.
                        DispatchQueue.main.async {
                            guard model.editingProjectID == projectID else { return }
                            focused = true
                            DispatchQueue.main.async {
                                guard model.editingProjectID == projectID else { return }
                                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                            }
                        }
                    }
                    .onChange(of: focused) { isFocused in
                        // Clicking elsewhere commits; blank restores the default.
                        if !isFocused, model.editingProjectID == projectID {
                            model.commitRename()
                        }
                    }
            }
        }
}
