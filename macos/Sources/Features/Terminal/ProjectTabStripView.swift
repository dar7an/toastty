import AppKit
import SwiftUI

/// Finder-style horizontal tab strip for one project.
///
/// Driven by the shared ``TabSidebarModel`` plus two closures so the same
/// view works both in an `NSSplitView` content header and in the native
/// `NSToolbar` hosting view (workstream C): it depends on neither parent
/// layout, has a fixed height (``stripHeight``) and a flexible width.
///
/// Tabs share a stable width regardless of selection. The rail scrolls once
/// there is no longer enough space to keep every title readable.
struct ProjectTabStripView: View {
    static let cellShape = Capsule()

    static let minimumCellWidth: CGFloat = 120

    /// Interior horizontal padding of the tab row (2pt per side).
    static let railPadding: CGFloat = 4

    /// Fixed row height, matching Safari's compact native tab rhythm.
    static let stripHeight: CGFloat = 32
    static let cellHeight: CGFloat = 28

    /// Width always reserved for the close button, even while hidden, so
    /// labels never jump when it appears.
    static let closeButtonWidth: CGFloat = 22

    static func cellWidths(
        available: CGFloat,
        count: Int,
        selectedIndex _: Int?
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let interior = available.isFinite ? max(0, floor(available - railPadding)) : 0
        let width = max(minimumCellWidth, floor(interior / CGFloat(count)))
        return Array(repeating: width, count: count)
    }

    @ObservedObject var model: TabSidebarModel
    @StateObject private var dragSession = TerminalLayoutDragSession()
    var onSelect: (TabSidebarModel.Row.ID) -> Void

    /// Shortcut hint for the tab at a visible index (e.g. the `goto_tab:N`
    /// key equivalent such as "⌘3"), shown in the tab tooltip. Defaults to
    /// no hints so plain constructions keep working.
    var shortcutHint: @MainActor (Int) -> String? = { _ in nil }

    var body: some View {
        rail
        .frame(height: Self.stripHeight)
        .background { ProjectTabRailBackground() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project tabs")
    }

    // MARK: - Rail

    private var rail: some View {
        GeometryReader { geometry in
            let selectedIndex = model.railTabs.firstIndex {
                $0.id == model.selection
            }
            let widths = Self.cellWidths(
                available: geometry.size.width,
                count: model.railTabs.count,
                selectedIndex: selectedIndex)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.railTabs.enumerated()), id: \.element.id) { index, row in
                            ProjectTabCellHost(
                                row: row,
                                isSelected: row.id == model.selection,
                                onSelect: onSelect,
                                showSeparator: showsSeparator(at: index),
                                shortcutHint: shortcutHint(index),
                                width: widths[index]
                            )
                            .id(row.id)
                        }
                    }
                    .modifier(ProjectTabScrollTargets())
                    .motionAnimation(.easeOut(duration: 0.18), value: model.liftedTabID)
                    .padding(.horizontal, Self.railPadding / 2)
                    .padding(.vertical, (Self.stripHeight - Self.cellHeight) / 2)
                }
                // Read-only: scrolling the rail must never change selection.
                .modifier(ProjectTabScrollPosition(target: Binding(get: { model.selection }, set: { _ in })))
                .contentShape(Rectangle())
                .onDrop(
                    of: [.toasttyTerminalLayoutID, .ghosttySurfaceId],
                    delegate: ProjectTabStripDropDelegate(model: model, session: dragSession))
                .onAppear { revealSelection(proxy) }
                .onChange(of: model.selection) { _ in revealSelection(proxy) }
                .onChange(of: model.railTabs.map(\.id)) { _ in revealSelection(proxy) }
                .onChange(of: geometry.size.width) { _ in revealSelection(proxy) }
            }
        }
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        // A bound scroll target survives the first layout of a newly shown
        // AppKit tab, when an imperative scrollTo can otherwise be lost.
        if #unavailable(macOS 14.0) {
            DispatchQueue.main.async {
                if let id = model.selection { proxy.scrollTo(id) }
            }
        }
    }

    // MARK: - Cells

    /// Separators sit between adjacent inactive tabs and are omitted beside
    /// the selected tab. They are overlays, so they take no layout width
    /// and the equal-share sizing stays exact.
    private func showsSeparator(at index: Int) -> Bool {
        let tabs = model.railTabs
        guard index > 0, index < tabs.count else { return false }
        return tabs[index].id != model.selection && tabs[index - 1].id != model.selection
    }

}

/// Tabs reorder along the rail; merging happens by dropping into a pane.
enum ProjectTabDropState: Equatable {
    case idle
    case before
    case after

    static func calculate(atX x: CGFloat, width: CGFloat) -> Self {
        guard width.isFinite, width > 0, x.isFinite else { return .idle }
        return x < width / 2 ? .before : .after
    }
}

/// A complete cell owns its hover/focus state and its row-local context menu.
struct ProjectTabCell: View {
    let row: TabSidebarModel.Row
    let isSelected: Bool
    let onSelect: (TabSidebarModel.Row.ID) -> Void
    let showSeparator: Bool
    // `var` (not `let`): defaulted `let` properties are excluded from the
    // synthesized memberwise initializer, which the host below relies on.
    var shortcutHint: String?
    let width: CGFloat
    var isHovered = false
    var isPressed = false
    @FocusState private var selectionFocused: Bool
    @FocusState private var closeFocused: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var dropState: ProjectTabDropState = .idle
    @StateObject private var dragSession = TerminalLayoutDragSession()
    @ObservedObject private var tabDragFeedback = ProjectTabDragSession.feedback

    /// Renders the tab cell and exposes only the movement actions available
    /// for the tab's current position.
    var body: some View {
        // Reserve equal space on both sides of the title. Revealing a close
        // button must not shift the label, including on the selected tab.
        let isCloseVisible = isSelected || isHovered || selectionFocused || closeFocused
        let movement = ProjectTabMovement(window: row.window)
        return ZStack(alignment: .leading) {
            Button { onSelect(row.id) } label: {
                Text(row.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, ProjectTabStripView.closeButtonWidth + 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: ProjectTabStripView.cellHeight)
                    .contentShape(ProjectTabStripView.cellShape)
            }
            .buttonStyle(.plain)
            .focused($selectionFocused)
            .accessibilityIdentifier("project-tab")
            .accessibilityActions {
                Button("Close Tab") {
                    (row.window.windowController as? TerminalController)?.closeTab(nil)
                }
                Button("Rename Tab") {
                    (row.window.windowController as? TerminalController)?.promptTabTitle()
                }
                if movement.canMove(by: -1) {
                    Button("Move Tab Left") { movement.move(by: -1) }
                }
                if movement.canMove(by: 1) {
                    Button("Move Tab Right") { movement.move(by: 1) }
                }
            }
            .accessibilityHint([row.pwd, shortcutHint,
                                "Double-click to rename. Drag to reorder or move to another window."]
                .compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(row.title)
            .accessibilityValue(row.tabColor == .none ? "" : "Color \(row.tabColor.localizedName)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button {
                (row.window.windowController as? TerminalController)?.closeTab(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: ProjectTabStripView.closeButtonWidth, height: 22)
                    .background {
                        if closeFocused {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isCloseVisible ? 1 : 0)
            .motionAnimation(.easeOut(duration: 0.1), value: isCloseVisible)
            .allowsHitTesting(isCloseVisible)
            .focused($closeFocused)
            .help("Close Tab")
            .accessibilityLabel("Close \(row.title)")
            .accessibilityIdentifier("project-tab-close")
            .padding(.leading, 4)
        }
        .frame(width: width, height: ProjectTabStripView.cellHeight)
        .background {
            ProjectTabChrome(
                isSelected: isSelected,
                isHovered: isHovered,
                isPressed: isPressed,
                isFocused: selectionFocused)
        }
        .motionAnimation(.easeOut(duration: 0.1), value: isHovered)
        .motionAnimation(.easeOut(duration: 0.08), value: isPressed)
        .overlay(alignment: .trailing) {
            if let color = row.tabColor.displayColor {
                Circle().fill(Color(nsColor: color))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            if showSeparator {
                Rectangle()
                    .fill(ProjectChrome.separatorColor)
                    .frame(width: ProjectChrome.hairline(displayScale: displayScale), height: 16)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            switch tabDragFeedback.railTarget?.windowID == row.id
                ? tabDragFeedback.railTarget?.position ?? .idle
                : (TerminalLayoutCoordinator.shared.canDropInTabBar(dragSession.payload, beside: row.window)
                   ? dropState : .idle) {
            case .idle:
                EmptyView()
            case .before:
                ProjectTabDropIndicator(alignment: .leading)
            case .after:
                ProjectTabDropIndicator(alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.toasttyTerminalLayoutID, .ghosttySurfaceId],
            delegate: ProjectTabCellDropDelegate(
                row: row,
                width: width,
                dropState: $dropState,
                session: dragSession))
        .motionAnimation(.easeOut(duration: 0.12), value: dropState)
    }

}

/// Resolves tab movement against the current project's visible order. Both
/// menu and accessibility actions use this value so unavailable directions
/// disappear at the ends of the rail and every move follows the drag path.
@MainActor
struct ProjectTabMovement {
    let window: NSWindow

    /// The terminal controller that owns the target window.
    private var controller: TerminalController? {
        window.windowController as? TerminalController
    }

    /// The target window's position among tabs in the same project.
    private var currentIndex: Int? {
        controller?.projectTabWindows.firstIndex(of: window)
    }

    /// The number of tabs that belong to the target window's project.
    var count: Int {
        controller?.projectTabWindows.count ?? 0
    }

    /// Returns whether moving by the given relative offset stays in the project.
    func canMove(by offset: Int) -> Bool {
        guard let currentIndex else { return false }
        return (0..<count).contains(currentIndex + offset)
    }

    /// Moves the target tab by the given relative offset when the destination exists.
    func move(by offset: Int) {
        guard let controller, let currentIndex, canMove(by: offset) else { return }
        TerminalLayoutCoordinator.shared.reorderTab(
            controller.projectTabID, toProjectIndex: currentIndex + offset)
    }
}

private struct ProjectTabDropIndicator: View {
    let alignment: Alignment

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 24)
            .frame(maxWidth: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }
}

private struct ProjectTabCellDropDelegate: DropDelegate {
    let row: TabSidebarModel.Row
    let width: CGFloat
    @Binding var dropState: ProjectTabDropState
    let session: TerminalLayoutDragSession

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.toasttyTerminalLayoutID, .ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        dropState = .calculate(atX: info.location.x, width: width)
        session.begin(info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId]))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropState = .calculate(atX: info.location.x, width: width)
        return DropProposal(operation:
            TerminalLayoutCoordinator.shared.canDropInTabBar(session.payload, beside: row.window) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        dropState = .idle
        session.end()
    }

    func performDrop(info: DropInfo) -> Bool {
        let position = ProjectTabDropState.calculate(atX: info.location.x, width: width)
        dropState = .idle
        guard position != .idle else { return false }

        if let payload = session.payload {
            guard TerminalLayoutCoordinator.shared.canDropInTabBar(payload, beside: row.window) else { return false }
            session.end()
            commit(payload, at: position)
            return true
        }

        // A fast drop can land before the session's asynchronous payload
        // publish; load the providers directly and commit on completion.
        return session.finishDrop(
            info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId])
        ) { payload in
            guard TerminalLayoutCoordinator.shared.canDropInTabBar(payload, beside: self.row.window) else { return }
            self.commit(payload, at: position)
        }
    }

    private func commit(_ payload: TerminalLayoutDragPayload, at position: ProjectTabDropState) {
        guard let target = row.window.windowController as? TerminalController else { return }
        let coordinator = TerminalLayoutCoordinator.shared

        switch payload {
        case .tab(let sourceID):
            switch position {
            case .before, .after:
                coordinator.insertTab(sourceID, beside: row.window, after: position == .after)
            case .idle:
                break
            }

        case .surface(let surfaceID):
            // A tab cell is the tab-bar surface, not a split pane. A pane
            // dropped here becomes a new tab, including when it is dropped
            // back onto the tab it came from.
            guard let targetIndex = target.projectTabWindows.firstIndex(of: row.window) else { return }
            let insertionIndex: Int = switch position {
            case .before: targetIndex
            case .after, .idle: targetIndex + 1
            }
            coordinator.extractSurface(
                surfaceID,
                beside: target.projectTabID,
                insertionIndex: insertionIndex)
        }
    }

}

private struct ProjectTabStripDropDelegate: DropDelegate {
    @ObservedObject var model: TabSidebarModel
    let session: TerminalLayoutDragSession

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.toasttyTerminalLayoutID, .ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        session.begin(info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId]))
    }

    func dropExited(info: DropInfo) { session.end() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = model.railTabs.last.map {
            TerminalLayoutCoordinator.shared.canDropInTabBar(session.payload, beside: $0.window)
        } ?? false
        return DropProposal(operation: valid ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let targetRow = model.railTabs.last,
              targetRow.window.windowController is TerminalController else { return false }

        if let payload = session.payload {
            guard TerminalLayoutCoordinator.shared.canDropInTabBar(payload, beside: targetRow.window) else { return false }
            session.end()
            commit(payload, beside: targetRow)
            return true
        }

        // A fast drop can land before the session's asynchronous payload
        // publish; load the providers directly and commit on completion.
        return session.finishDrop(
            info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId])
        ) { payload in
            guard TerminalLayoutCoordinator.shared.canDropInTabBar(payload, beside: targetRow.window) else { return }
            self.commit(payload, beside: targetRow)
        }
    }

    private func commit(_ payload: TerminalLayoutDragPayload, beside targetRow: TabSidebarModel.Row) {
        guard let target = targetRow.window.windowController as? TerminalController else { return }
        switch payload {
        case .tab(let sourceID):
            TerminalLayoutCoordinator.shared.insertTab(sourceID, beside: targetRow.window, after: true)
        case .surface(let surfaceID):
            TerminalLayoutCoordinator.shared.extractSurface(
                surfaceID, beside: target.projectTabID, insertionIndex: target.projectTabWindows.count)
        }
    }
}

/// A native host keeps right-clicks inside the tab instead of allowing the
/// toolbar to substitute its own item-customization menu.
private struct ProjectTabCellHost: NSViewRepresentable {
    let row: TabSidebarModel.Row
    let isSelected: Bool
    let onSelect: (TabSidebarModel.Row.ID) -> Void
    let showSeparator: Bool
    let shortcutHint: String?
    let width: CGFloat

    private var cell: ProjectTabCell {
        ProjectTabCell(row: row, isSelected: isSelected, onSelect: onSelect,
                       showSeparator: showSeparator, shortcutHint: shortcutHint, width: width)
    }

    func makeNSView(context: Context) -> ProjectTabCellHostingView {
        ProjectTabCellHostingView(rootView: cell)
    }

    func updateNSView(_ view: ProjectTabCellHostingView, context: Context) {
        view.update(cell)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProjectTabCellHostingView,
                      context: Context) -> CGSize? {
        CGSize(width: width, height: ProjectTabStripView.cellHeight)
    }
}

final class ProjectTabCellHostingView: NonDraggableHostingView<ProjectTabCell> {
    static let tearOffDistance: CGFloat = 28

    private var hoverTrackingArea: NSTrackingArea?
    private var tabIsHovered = false
    private var mouseDownPoint: NSPoint?
    private var pressedClose = false
    private var reorderGesture: ProjectTabReorderGesture?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Click-through may select a tab, but must not destroy a terminal
        // when the user is only trying to activate an inactive window.
        guard let event else { return false }
        return !closeButtonRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            ProjectTabHoverPreview.shared.leave(self)
            reorderGesture?.finish(commit: false, animated: false)
            reorderGesture = nil
            mouseDownPoint = nil
            setHovered(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // One native handler owns click-versus-drag arbitration. SwiftUI's
    // onDrag on a Button inside a toolbar can consume the initial click.
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else {
            rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        pressedClose = closeButtonRect.contains(point)
        setHovered(true)
        ProjectTabHoverPreview.shared.dismiss()
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        setHovered(bounds.contains(point))
        if let reorderGesture {
            self.reorderGesture = nil
            reorderGesture.finish(commit: true)
            setHovered(false)
            return
        }
        guard bounds.contains(point) else { return }
        if pressedClose {
            if closeButtonRect.contains(point) {
                (rootView.row.window.windowController as? TerminalController)?.closeTab(nil)
            }
        } else {
            if rootView.row.window.projectSidebarModel.recordTabClick(rootView.row.id, timestamp: event.timestamp) {
                (rootView.row.window.windowController as? TerminalController)?.promptTabTitle()
            } else {
                rootView.onSelect(rootView.row.id)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, !pressedClose,
              rootView.row.window.windowController is TerminalController else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return }
        rootView.row.window.projectSidebarModel.cancelTabClick()
        // Stay attached to the rail for horizontal reordering. Pulling beyond
        // the tab row lifts a window preview into a continuous drag gesture,
        // which can still land on a terminal pane or return to the rail.
        if abs(point.y - origin.y) <= Self.tearOffDistance && isWithinReorderRail(event) {
            if reorderGesture == nil {
                reorderGesture = ProjectTabReorderGesture(source: self)
                reorderGesture?.onCancel = { [weak self] in
                    self?.mouseDownPoint = nil
                    self?.reorderGesture = nil
                    self?.setHovered(false)
                }
            }
            if let reorderGesture {
                setHovered(false)
                // AppKit scrolls an overflowing rail at its edges while the
                // drag remains captured by this cell.
                _ = autoscroll(with: event)
                let scrolledPoint = convert(event.locationInWindow, from: nil)
                reorderGesture.update(translation: scrolledPoint.x - origin.x)
                return
            }
        }
        reorderGesture?.finish(commit: false, animated: false)
        reorderGesture = nil
        mouseDownPoint = nil
        setHovered(false)
        ProjectTabDragSession.begin(from: self, event: event, grabPoint: origin)
    }

    private func isWithinReorderRail(_ event: NSEvent) -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if view is ProjectTabStripHostingView {
                let point = view.convert(event.locationInWindow, from: nil)
                return point.x >= view.bounds.minX - 8 && point.x <= view.bounds.maxX + 8
            }
            ancestor = view.superview
        }
        return true
    }

    @discardableResult
    func detachForWindowDrag() -> Bool {
        let window = rootView.row.window
        guard let tabGroup = window.tabGroup, tabGroup.windows.count > 1 else { return false }
        tabGroup.selectedWindow = window
        window.moveTabToNewWindow(nil)
        tabGroup.tabSidebarModel.refresh()
        Self.syncDetachedChrome(for: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.syncDetachedChrome(for: window)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private static func syncDetachedChrome(for window: NSWindow) {
        let model = window.projectSidebarModel
        model.refresh()
        (window.contentView as? TerminalViewContainer)?
            .projectSplitViewController?.bind(to: model, animated: false)
    }

    private var closeButtonRect: NSRect {
        NSRect(
            x: 4,
            y: (bounds.height - 22) / 2,
            width: ProjectTabStripView.closeButtonWidth,
            height: 22)
    }

    func update(_ cell: ProjectTabCell) {
        var cell = cell
        cell.isHovered = tabIsHovered
        cell.isPressed = tabIsHovered && mouseDownPoint != nil && reorderGesture == nil && !pressedClose
        rootView = cell
        ProjectTabHoverPreview.shared.validate(self)
    }

    /// Non-clipping SwiftUI hosts can report the entire rail as visibleRect.
    /// Restrict preview placement and hover tracking to this tab's visible part.
    var hoverPreviewRect: NSRect { bounds.intersection(visibleRect) }

    /// In full screen AppKit may host the toolbar in an auxiliary window.
    /// The selected terminal, not that non-key host, owns interaction focus.
    var previewInteractionWindow: NSWindow? {
        guard let window else { return nil }
        if window.isKeyWindow { return window }
        return rootView.row.window.tabGroup?.selectedWindow ?? window
    }

    var canShowHoverPreview: Bool {
        !rootView.isSelected && mouseDownPoint == nil && reorderGesture == nil &&
            window?.isVisible == true &&
            previewInteractionWindow?.attachedSheet == nil &&
            !isHiddenOrHasHiddenAncestor && !hoverPreviewRect.isEmpty &&
            rootView.row.window.projectSidebarModel.liftedTabID == nil
    }

    func canShowHoverPreview(at point: NSPoint) -> Bool {
        canShowHoverPreview && hoverPreviewRect.contains(point) && !closeButtonRect.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                 owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        if let window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        ProjectTabHoverPreview.shared.hover(self, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        ProjectTabHoverPreview.shared.leave(self)
    }

    fileprivate func setHovered(_ hovered: Bool) {
        let pressed = hovered && mouseDownPoint != nil && reorderGesture == nil && !pressedClose
        guard tabIsHovered != hovered || rootView.isPressed != pressed else { return }
        tabIsHovered = hovered
        rootView.isHovered = hovered
        rootView.isPressed = pressed
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ProjectTabHoverPreview.shared.dismiss()
        return makeProjectTabContextMenu(for: rootView.row.window)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// AppKit can open the toolbar customization menu before a hosted tab's
/// rightMouseDown. A view-scoped local monitor handles only context clicks on
/// actual tab cells, including when the host moves to a fullscreen toolbar.
/// Ordinary clicks, scrolling, other controls, and other windows stay native.
final class ProjectTabStripHostingView: NonDraggableHostingView<AnyView> {
    private var eventMonitor: Any?
    private weak var hoveredCell: ProjectTabCellHostingView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return event }
            let cell = self.cell(for: event)
            // Toolbar event routing can skip a hosted view's tracking area,
            // especially after switching native tab windows. Synchronize
            // hover from the actual hit view without consuming ordinary input.
            if self.hoveredCell !== cell {
                self.hoveredCell?.setHovered(false)
                self.hoveredCell = cell
            }
            cell?.setHovered(true)
            if event.type == .mouseMoved, let cell {
                ProjectTabHoverPreview.shared.hover(cell, at: cell.convert(event.locationInWindow, from: nil))
            }
            guard event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  let menu = cell?.menu(for: event) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cell(for: event)?.menu(for: event)
    }

    private func cell(for event: NSEvent) -> ProjectTabCellHostingView? {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        var view = hitTest(superview?.convert(event.locationInWindow, from: nil) ?? .zero)
        while let candidate = view, candidate !== self {
            if let cell = candidate as? ProjectTabCellHostingView { return cell }
            view = candidate.superview
        }
        return nil
    }
}

/// Builds the project-tab context menu for the supplied terminal window.
@MainActor
func makeProjectTabContextMenu(for window: NSWindow) -> NSMenu {
    let menu = NSMenu()
    let controller = window.windowController as? TerminalController
    let movement = ProjectTabMovement(window: window)
    if let surface = controller?.focusedSurface {
        TerminalPaneLayoutMenu.append(to: menu, surface: surface)
        menu.addItem(.separator())
    }
    if let controller {
        menu.addItem(ProjectTabMenuItem("Rename Tab…") { [weak controller] in controller?.promptTabTitle() })
        if movement.canMove(by: -1) {
            menu.addItem(ProjectTabMenuItem("Move Tab Left") { movement.move(by: -1) })
        }
        if movement.canMove(by: 1) {
            menu.addItem(ProjectTabMenuItem("Move Tab Right") { movement.move(by: 1) })
        }
        // Same detach action as the native tab menu's `moveTabToNewWindow:`.
        if (window.tabGroup?.windows.count ?? 0) > 1 {
            menu.addItem(ProjectTabMenuItem("Move Tab to New Window") { [weak window] in
                window?.moveTabToNewWindow(nil)
            })
        }
        menu.addItem(.separator())
    }
    if #available(macOS 14.0, *) {
        menu.addItem(.sectionHeader(title: "Tab Color"))
    } else {
        let header = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }
    let palette = makeProjectTabColorMenu(selected: (window as? TerminalWindow)?.tabColor ?? .none) { [weak window] color in
        (window as? TerminalWindow)?.tabColor = color
    }
    for item in palette.items {
        palette.removeItem(item)
        menu.addItem(item)
    }
    if let controller {
        menu.addItem(.separator())
        menu.addItem(ProjectTabMenuItem("Close Tab") { [weak controller] in controller?.closeTab(nil) })
        if movement.count > 1 {
            menu.addItem(ProjectTabMenuItem("Close Other Tabs") { [weak controller] in
                controller?.closeOtherTabs(nil)
            })
        }
        if movement.canMove(by: 1) {
            menu.addItem(ProjectTabMenuItem("Close Tabs to the Right") { [weak controller] in
                controller?.closeTabsOnTheRight(nil)
            })
        }
    }
    return menu
}

final class ProjectTabMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}

private struct ProjectTabScrollTargets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.scrollTargetLayout()
        } else {
            content
        }
    }
}

private struct ProjectTabScrollPosition: ViewModifier {
    @Binding var target: ObjectIdentifier?

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.scrollPosition(id: $target, anchor: .center)
        } else {
            content
        }
    }
}
