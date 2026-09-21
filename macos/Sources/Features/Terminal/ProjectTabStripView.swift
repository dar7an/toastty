import AppKit
import SwiftUI

/// Finder-style horizontal tab strip for one project.
///
/// Driven by the shared ``TabSidebarModel`` plus two closures so the same
/// view works both in an `NSSplitView` content header and in the native
/// `NSToolbar` hosting view (workstream C): it depends on neither parent
/// layout, has a fixed height (``stripHeight``) and a flexible width.
///
/// The selected tab keeps its title while inactive tabs compress toward
/// icon-only cells. The rail scrolls only after the selected tab and compact
/// inactive cells no longer fit.
struct ProjectTabStripView: View {
    static let cellShape = Capsule()

    static let compactCellWidth: CGFloat = 54
    static let minimumSelectedWidth: CGFloat = 120
    static let selectedPreferredWidth: CGFloat = 190
    static let selectedWidthBonus: CGFloat = 40
    static let compactLabelThreshold: CGFloat = 84

    /// Interior horizontal padding of the tab row (2pt per side).
    static let railPadding: CGFloat = 4

    /// Fixed row height, matching Safari's compact native tab rhythm.
    static let stripHeight: CGFloat = 32
    static let cellHeight: CGFloat = 28

    /// Width always reserved for the close button, even while hidden, so
    /// labels never jump when it appears.
    static let closeButtonWidth: CGFloat = 20

    static func cellWidths(
        available: CGFloat,
        count: Int,
        selectedIndex: Int?
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let interior = max(0, floor(available - railPadding))
        guard count > 1 else {
            return [max(minimumSelectedWidth, interior)]
        }
        guard let selectedIndex, (0..<count).contains(selectedIndex) else {
            let width = max(compactCellWidth, floor(interior / CGFloat(count)))
            return Array(repeating: width, count: count)
        }

        let equalBase = floor((interior - selectedWidthBonus) / CGFloat(count))
        let equalSelected = equalBase + selectedWidthBonus
        let compactPreservingSelected = min(
            selectedPreferredWidth,
            interior - compactCellWidth * CGFloat(count - 1))
        var selectedWidth = max(equalSelected, compactPreservingSelected)
        var inactiveWidth = floor(
            (interior - selectedWidth) / CGFloat(count - 1))

        if inactiveWidth < compactCellWidth {
            inactiveWidth = compactCellWidth
            selectedWidth = max(
                minimumSelectedWidth,
                interior - inactiveWidth * CGFloat(count - 1))
        }

        var widths = Array(repeating: inactiveWidth, count: count)
        widths[selectedIndex] = max(minimumSelectedWidth, selectedWidth)
        return widths
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project tabs")
    }

    // MARK: - Rail

    private var rail: some View {
        GeometryReader { geometry in
            let selectedIndex = model.visibleTabs.firstIndex {
                $0.id == model.selection
            }
            let widths = Self.cellWidths(
                available: geometry.size.width,
                count: model.visibleTabs.count,
                selectedIndex: selectedIndex)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.visibleTabs.enumerated()), id: \.element.id) { index, row in
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
                    .motionAnimation(.easeOut(duration: 0.18), value: model.selection)
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
                .onChange(of: model.visibleTabs.map(\.id)) { _ in revealSelection(proxy) }
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
        let tabs = model.visibleTabs
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
    @FocusState private var closeFocused: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var dropState: ProjectTabDropState = .idle
    @StateObject private var dragSession = TerminalLayoutDragSession()

    var body: some View {
        // Reserve equal space on both sides of the title. Revealing a close
        // button must not shift the label, including on the selected tab.
        let isCloseVisible = isHovered || closeFocused
        return ZStack(alignment: .leading) {
            Button { onSelect(row.id) } label: {
                Group {
                    if !isSelected && width < ProjectTabStripView.compactLabelThreshold {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(row.title)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, ProjectTabStripView.closeButtonWidth + 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: ProjectTabStripView.cellHeight)
                .contentShape(ProjectTabStripView.cellShape)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Drag to reorder this tab or drop it into another terminal split.")
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
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isCloseVisible ? 1 : 0)
            .motionAnimation(.easeOut(duration: 0.1), value: isCloseVisible)
            .allowsHitTesting(isCloseVisible)
            .focused($closeFocused)
            .help("Close Tab")
            .accessibilityLabel("Close \(row.title)")
            .padding(.leading, 4)
        }
        .frame(width: width, height: ProjectTabStripView.cellHeight)
        .background {
            if isSelected {
                Color.clear.modifier(ProjectGlass(shape: ProjectTabStripView.cellShape, interactive: true))
            } else if isHovered {
                ProjectTabStripView.cellShape.fill(.primary.opacity(0.06))
            }
        }
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
            switch TerminalLayoutCoordinator.shared.canDropInTabBar(dragSession.payload, beside: row.window)
                ? dropState : .idle {
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
        .help([row.title, row.pwd, shortcutHint].compactMap { $0 }.joined(separator: "\n"))
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
                reorderTab(sourceID, into: target, after: position == .after)
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

    private func reorderTab(
        _ sourceID: UUID,
        into target: TerminalController,
        after: Bool
    ) {
        guard let source = TerminalController.all.first(where: { $0.projectTabID == sourceID }),
              let sourceWindow = source.window,
              let targetIndex = target.projectTabWindows.firstIndex(of: row.window),
              let sourceIndex = target.projectTabWindows.firstIndex(of: sourceWindow),
              source.project.id == target.project.id,
              sourceWindow.tabGroup === row.window.tabGroup,
              sourceWindow !== row.window else { return }

        let insertionIndex = after ? targetIndex + 1 : targetIndex
        let finalIndex = insertionIndex - (sourceIndex < insertionIndex ? 1 : 0)
        TerminalLayoutCoordinator.shared.reorderTab(sourceID, toProjectIndex: finalIndex)
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
        let valid = model.visibleTabs.last.map {
            TerminalLayoutCoordinator.shared.canDropInTabBar(session.payload, beside: $0.window)
        } ?? false
        return DropProposal(operation: valid ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let targetRow = model.visibleTabs.last,
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
            TerminalLayoutCoordinator.shared.reorderTab(
                sourceID, toProjectIndex: max(0, target.projectTabWindows.count - 1))
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
    private var hoverTrackingArea: NSTrackingArea?
    private var tabIsHovered = false
    private var mouseDownPoint: NSPoint?
    private var pressedClose = false
    private let tabDragSource = ProjectTabDragSource()
    private var reorderGesture: ProjectTabReorderGesture?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            reorderGesture?.finish(commit: false, animated: false)
            reorderGesture = nil
            mouseDownPoint = nil
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
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        if let reorderGesture {
            self.reorderGesture = nil
            reorderGesture.finish(commit: true)
            setHovered(false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if pressedClose {
            if closeButtonRect.contains(point) {
                (rootView.row.window.windowController as? TerminalController)?.closeTab(nil)
            }
        } else {
            rootView.onSelect(rootView.row.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, !pressedClose,
              let controller = rootView.row.window.windowController as? TerminalController else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return }
        // Stay attached to the rail for horizontal reordering, like Finder.
        // Crossing out of the rail deliberately starts a pane-transfer drag.
        if abs(point.y - origin.y) <= 28 {
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
        let pasteboard = NSPasteboardItem()
        guard let data = try? JSONEncoder().encode(TerminalLayoutDragPayload.tab(controller.projectTabID)) else { return }
        pasteboard.setData(data, forType: .toasttyTerminalLayoutID)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        setHovered(false)
        layoutSubtreeIfNeeded()
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y), contents: image)
        tabDragSource.onEnd = { [weak self] in self?.setHovered(false) }
        beginDraggingSession(with: [item], event: event, source: tabDragSource)
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
        rootView = cell
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

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    fileprivate func setHovered(_ hovered: Bool) {
        guard tabIsHovered != hovered else { return }
        tabIsHovered = hovered
        rootView.isHovered = hovered
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeProjectTabContextMenu(for: rootView.row.window)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// NSHostingView has its own sealed SwiftUI drag-source implementation.
/// Keep our native session's delegate separate from that implementation.
private final class ProjectTabDragSource: NSObject, NSDraggingSource {
    var onEnd: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd?()
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
func makeProjectTabContextMenu(for window: NSWindow) -> NSMenu {
    let menu = NSMenu()
    let controller = window.windowController as? TerminalController
    if let surface = controller?.focusedSurface {
        TerminalPaneLayoutMenu.append(to: menu, surface: surface)
        menu.addItem(.separator())
    }
    menu.addItem(ProjectTabMenuItem("Rename Tab…") { [weak controller] in controller?.promptTabTitle() })
    menu.addItem(ProjectTabMenuItem("Close Tab") { [weak controller] in controller?.closeTab(nil) })
    menu.addItem(ProjectTabMenuItem("Close Other Tabs") { [weak controller] in controller?.closeOtherTabs(nil) })
    menu.addItem(ProjectTabMenuItem("Close Tabs to the Right") { [weak controller] in
        controller?.closeTabsOnTheRight(nil)
    })
    // Same detach action as the native tab menu's `moveTabToNewWindow:`
    // (NSWindow API, always present where native tabs exist).
    let moveItem = ProjectTabMenuItem("Move Tab to New Window") { [weak window] in
        window?.moveTabToNewWindow(nil)
    }
    moveItem.isEnabled = (window.tabGroup?.windows.count ?? 0) > 1
    menu.addItem(moveItem)
    menu.addItem(.separator())
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

/// Tinted Liquid Glass on macOS 26+, material fallback below. Never
/// simulated with gradients or shadows.
struct ProjectGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.3), lineWidth: 1))
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(
                    .regular
                        .tint(Color(nsColor: .controlBackgroundColor))
                        .interactive(interactive),
                    in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
#else
            content.background(.regularMaterial, in: shape)
#endif
        }
    }
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
