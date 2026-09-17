import AppKit
import SwiftUI

/// Finder-style horizontal tab strip for one project.
///
/// Driven by the shared ``TabSidebarModel`` plus two closures so the same
/// view works both in an `NSSplitView` content header and in the native
/// `NSToolbar` hosting view (workstream C): it depends on neither parent
/// layout, has a fixed height (``stripHeight``) and a flexible width.
///
/// Sizing formula: the capsule rail reserves ``capsulePadding`` points of
/// interior horizontal padding (3pt on each side). The remaining width is
/// divided equally among all tabs and floored to whole points, so every
/// complete tab cell — close space, label and cell padding included — has
/// the same width:
///
///     cellWidth = max(minCellWidth, floor((available - capsulePadding) / count))
///
/// While the equal share fits, tabs fill the rail exactly (inter-cell
/// separators are overlays and consume no layout width). Once the share
/// would drop below ``minCellWidth``, every cell stays at ``minCellWidth``
/// and the rail scrolls horizontally instead of shrinking further. The
/// strip is always shown, even for a single tab.
struct ProjectTabStripView: View {
    /// Minimum width of one complete tab cell. Below this the rail
    /// overflows into horizontal scrolling.
    static let minCellWidth: CGFloat = 96

    /// Interior horizontal padding of the capsule rail (3pt per side).
    static let capsulePadding: CGFloat = 6

    /// Fixed strip height, matching the header slot and toolbar items.
    static let stripHeight: CGFloat = 32

    /// Width always reserved for the close button, even while hidden, so
    /// labels never jump when it appears.
    static let closeButtonWidth: CGFloat = 20

    /// Equal cell width for `count` tabs in `available` points of rail.
    /// See the type documentation for the formula.
    static func cellWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minCellWidth }
        return max(minCellWidth, floor((available - capsulePadding) / CGFloat(count)))
    }

    @ObservedObject var model: TabSidebarModel
    var onSelect: (TabSidebarModel.Row.ID) -> Void

    var body: some View {
        rail
        .frame(height: Self.stripHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project tabs")
    }

    // MARK: - Rail

    private var rail: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(model.visibleTabs.enumerated()), id: \.element.id) { index, row in
                            ProjectTabCellHost(
                                row: row,
                                isSelected: row.id == model.selection,
                                onSelect: onSelect,
                                showSeparator: showsSeparator(at: index),
                                width: Self.cellWidth(
                                    available: geometry.size.width,
                                    count: model.visibleTabs.count)
                            )
                            .id(row.id)
                        }
                    }
                    .modifier(ProjectTabScrollTargets())
                    .padding(3)
                }
                // Read-only: scrolling the rail must never change selection.
                .modifier(ProjectTabScrollPosition(target: Binding(get: { model.selection }, set: { _ in })))
                .background(.quaternary.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
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

/// A complete cell owns its hover/focus state and its row-local context menu.
struct ProjectTabCell: View {
    let row: TabSidebarModel.Row
    let isSelected: Bool
    let onSelect: (TabSidebarModel.Row.ID) -> Void
    let showSeparator: Bool
    let width: CGFloat
    var isHovered = false
    @FocusState private var closeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reserve equal space on both sides of the title. Revealing a close
        // button must not shift the label, including on the selected tab.
        let isCloseVisible = isHovered || closeFocused
        return ZStack(alignment: .leading) {
            Button { onSelect(row.id) } label: {
                Text(row.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ProjectTabStripView.closeButtonWidth + 8)
                    .frame(height: 26)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isCloseVisible)
            .allowsHitTesting(isCloseVisible)
            .focused($closeFocused)
            .help("Close Tab")
            .accessibilityLabel("Close \(row.title)")
            .padding(.leading, 4)
        }
        .frame(width: width, height: 26)
        .background {
            if isSelected {
                Color.clear.modifier(ProjectGlass())
            } else if isHovered {
                Capsule().fill(.primary.opacity(0.05))
            }
        }
        .overlay(alignment: .trailing) {
            if let color = row.tabColor.displayColor {
                Circle().fill(Color(nsColor: color))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 11)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showSeparator {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 14)
            }
        }
        .help([row.title, row.pwd].compactMap { $0 }.joined(separator: "\n"))
    }

}

/// A native host keeps right-clicks inside the tab instead of allowing the
/// toolbar to substitute its own item-customization menu.
private struct ProjectTabCellHost: NSViewRepresentable {
    let row: TabSidebarModel.Row
    let isSelected: Bool
    let onSelect: (TabSidebarModel.Row.ID) -> Void
    let showSeparator: Bool
    let width: CGFloat

    private var cell: ProjectTabCell {
        ProjectTabCell(row: row, isSelected: isSelected, onSelect: onSelect,
                       showSeparator: showSeparator, width: width)
    }

    func makeNSView(context: Context) -> ProjectTabCellHostingView {
        ProjectTabCellHostingView(rootView: cell)
    }

    func updateNSView(_ view: ProjectTabCellHostingView, context: Context) {
        view.update(cell)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProjectTabCellHostingView,
                      context: Context) -> CGSize? {
        CGSize(width: width, height: 26)
    }
}

private final class ProjectTabCellHostingView: NonDraggableHostingView<ProjectTabCell> {
    private var hoverTrackingArea: NSTrackingArea?
    private var tabIsHovered = false

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
    menu.addItem(.separator())
    let palette = makeProjectTabColorMenu(selected: (window as? TerminalWindow)?.tabColor ?? .none) { [weak window] color in
        (window as? TerminalWindow)?.tabColor = color
    }
    for item in palette.items {
        palette.removeItem(item)
        menu.addItem(item)
    }
    return menu
}

private final class ProjectTabMenuItem: NSMenuItem {
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

/// Liquid Glass capsule on macOS 26+, material fallback below. Never
/// simulated with gradients or shadows.
struct ProjectGlass: ViewModifier {
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.3), lineWidth: 1))
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(interactive), in: Capsule())
            } else {
                content.background(.regularMaterial, in: Capsule())
            }
#else
            content.background(.regularMaterial, in: Capsule())
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
