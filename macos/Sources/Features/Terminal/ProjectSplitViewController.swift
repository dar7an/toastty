import AppKit
import Combine
import SwiftUI

/// Native AppKit composition for the project sidebar and toolbar (workstream C).
///
/// `TerminalView` renders only the terminal tree (splits, focus environment,
/// overlays). Everything around it — the collapsible project sidebar and the
/// single-row unified toolbar — is composed here with AppKit:
///
/// - `ProjectSplitViewController` is an `NSSplitViewController` whose sidebar
///   item hosts ``ProjectSidebarListView`` and whose content item hosts the
///   terminal `NSHostingController`. The native divider owns the 160–320pt
///   width range, collapse animation (skipped when Reduce Motion is on), and
///   previous-width restoration.
/// - `ProjectToolbarDelegate` builds the one native toolbar row:
///   `[traffic lights sidebar toggle] | [project tabs …][+]`, where the tab
///   strip is the shared ``ProjectTabStripView`` in a borderless flexible
///   item and the separator tracks the sidebar divider.
///
/// State flow is one-way through the shared ``TabSidebarModel``:
/// user gesture → `NSSplitViewItem` → `model.sidebarState` → all member
/// windows apply. `isSyncing`/`suppressObservation` guard the two-way
/// split/model sync against loops.
final class ProjectSplitViewController: NSSplitViewController {
    private weak var terminalController: TerminalController?

    let sidebarSplitItem: NSSplitViewItem
    let contentSplitItem: NSSplitViewItem
    private let sidebarHostingController: NSHostingController<AnyView>
    private let contentHostingController: NSHostingController<AnyView>

    /// Retained toolbar coordinator. `NSToolbar.delegate` is weak, so the
    /// split controller owns it; the delegate points back weakly.
    private(set) var toolbarDelegate: ProjectToolbarDelegate!

    private(set) var model: TabSidebarModel?
    private var modelCancellable: AnyCancellable?
    private var windowCancellable: AnyCancellable?
    private var tabGroupCancellable: AnyCancellable?
    private var resizeCancellable: AnyCancellable?
    private var resizeWorkItem: DispatchWorkItem?
    private var animationGeneration = 0

    /// True while a model→split apply is mutating the split view, so the
    /// resulting layout pass is not mistaken for a user resize.
    private var isSyncing = false

    /// True while a programmatic collapse/expand transition (including its
    /// collapse animation) is in flight, so intermediate divider positions
    /// are not recorded as the user's restored width.
    private var suppressObservation = false

    private var didApplyInitialLayout = false

    /// State captured before the view loads (inherited, restored, or undone).
    /// Applied once on the first layout, when divider positions are real.
    private var pendingInitialState: SidebarState?

    init(controller: TerminalController, content: AnyView) {
        self.terminalController = controller
        self.sidebarHostingController = NSHostingController(rootView: AnyView(EmptyView()))
        self.contentHostingController = NSHostingController(rootView: content)
        self.sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        self.contentSplitItem = NSSplitViewItem(viewController: contentHostingController)
        self.pendingInitialState = controller.sidebarState
        super.init(nibName: nil, bundle: nil)
        // Set orientation before adding items: AppKit installs their thickness
        // constraints along the current split axis.
        splitView.isVertical = true
        sidebarSplitItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarSplitItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarSplitItem.isCollapsed = controller.sidebarState?.isVisible == false
        addSplitViewItem(sidebarSplitItem)
        addSplitViewItem(contentSplitItem)
        sidebarSplitItem.minimumThickness = TabSidebarModel.minWidth
        sidebarSplitItem.maximumThickness = TabSidebarModel.maxWidth
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.allowsFullHeightLayout = true
        sidebarSplitItem.titlebarSeparatorStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        // Width/visibility are owned by TabSidebarModel, not AppKit autosave.
        splitView.autosaveName = nil
        toolbarDelegate = ProjectToolbarDelegate(
            splitController: self,
            controller: terminalController)
        toolbarDelegate.updateTabStripModel(model)
        resizeCancellable = NotificationCenter.default.publisher(
            for: NSSplitView.didResizeSubviewsNotification, object: splitView)
            .sink { [weak self] _ in self?.scheduleSidebarMeasurement() }
    }

    func applyInitialLayout() {
        guard !didApplyInitialLayout, let model, splitView.window != nil,
              splitView.bounds.width > 0 else { return }
        didApplyInitialLayout = true
        let state = pendingInitialState ?? model.sidebarState
        pendingInitialState = nil
        applySidebarState(state, animated: false)
    }

    private func scheduleSidebarMeasurement() {
        guard didApplyInitialLayout, !isSyncing, !suppressObservation else { return }
        resizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recordSidebarMeasurement() }
        resizeWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func recordSidebarMeasurement() {
        guard didApplyInitialLayout, !isSyncing, !suppressObservation,
              let model, let window = terminalController?.window,
              (window.tabGroup?.selectedWindow ?? window) === window else { return }
        let collapsed = sidebarSplitItem.isCollapsed
        if collapsed != !model.sidebarState.isVisible {
            model.setVisible(!collapsed)
        }
        if !collapsed {
            let width = sidebarColumnWidth
            if width >= TabSidebarModel.minWidth,
               abs(width - model.width) >= 0.5 {
                model.setExpandedWidth(width)
            }
        }
    }

    /// The divider positions refer to the split column, not its hosted view.
    /// AppKit may inset sidebar content (notably on macOS 26), so measuring
    /// that content would gradually shrink the saved width on each layout.
    var sidebarColumnWidth: CGFloat {
        splitView.arrangedSubviews.first?.frame.width ?? 0
    }

    /// The terminal hosting view, used by `TerminalViewContainer` for
    /// intrinsic-size fallback while SwiftUI focus state is still settling.
    var contentViewForSizing: NSView {
        contentHostingController.view
    }

    /// Binds the split view to a tab group's shared model, adopting the
    /// destination group's state. New tabs inherit before window loading via
    /// the controller's pending state; tabs moved into an existing group
    /// adopt that group here.
    func bind(to model: TabSidebarModel?, animated: Bool) {
        guard self.model !== model else { return }
        modelCancellable = nil
        self.model = model
        guard let model, let controller = terminalController else {
            sidebarHostingController.rootView = AnyView(EmptyView())
            toolbarDelegate?.updateTabStripModel(nil)
            return
        }
        pendingInitialState = model.sidebarState
        controller.sidebarState = model.sidebarState
        sidebarHostingController.rootView = AnyView(
            ProjectSidebarListView(model: model, controller: controller)
                .id(ObjectIdentifier(model)))
        toolbarDelegate?.updateTabStripModel(model)
        modelCancellable = model.$sidebarState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.terminalController?.sidebarState = state
                self.applySidebarState(state, animated: true)
            }
        applySidebarState(model.sidebarState, animated: animated)
    }

    /// Reconcile against current membership after AppKit finishes tabbing.
    /// Queued KVO values can describe an intermediate or already-empty group;
    /// never let one rebind the sidebar and toolbar to an obsolete model.
    func beginObservingTabGroup() {
        guard let controller = terminalController else { return }
        windowCancellable = controller.publisher(for: \.window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] _ in
                guard let self else { return }
                self.tabGroupCancellable = nil
                guard let window = controller?.window else {
                    self.bind(to: nil, animated: false)
                    return
                }
                self.tabGroupCancellable = window.publisher(for: \.tabGroup)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak window] _ in
                        guard let self, let window,
                              self.terminalController?.window === window else { return }
                        self.bind(
                            to: window.projectSidebarModel,
                            animated: false)
                    }
            }
    }

    /// Applies shared state to the split item. Collapse reallocates space to
    /// the content item without changing the outer window frame; expansion
    /// restores the previous width. Honors Reduce Motion by skipping the
    /// native collapse animation.
    func applySidebarState(_ state: SidebarState, animated: Bool) {
        guard isViewLoaded, didApplyInitialLayout else {
            pendingInitialState = state
            return
        }
        let targetCollapsed = !state.isVisible
        let visibilityChanged = sidebarSplitItem.isCollapsed != targetCollapsed
        let currentWidth = sidebarColumnWidth
        let widthSettled = targetCollapsed
            || abs(currentWidth - state.expandedWidth) < 0.5
        if sidebarSplitItem.isCollapsed == targetCollapsed && widthSettled {
            return
        }
        pendingInitialState = nil
        resizeWorkItem?.cancel()
        animationGeneration += 1
        let generation = animationGeneration
        isSyncing = true
        suppressObservation = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Hidden native tabs share the model. Animating all of them causes
        // every terminal to relayout on every animation frame. Width changes
        // during a divider drag also need to follow the pointer immediately.
        let window = terminalController?.window
        let isSelectedWindow = window.map { ($0.tabGroup?.selectedWindow ?? $0) === $0 } ?? false
        let animate = animated && visibilityChanged && !reduceMotion
            && window?.isVisible == true && isSelectedWindow
        if animate {
            NSAnimationContext.runAnimationGroup { [self] context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // One native animator owns the transition. A second animated
                // divider position competes with AppKit's width restoration.
                sidebarSplitItem.animator().isCollapsed = targetCollapsed
            } completionHandler: { [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                if state.isVisible, abs(self.sidebarColumnWidth - state.expandedWidth) >= 0.5 {
                    self.splitView.setPosition(state.expandedWidth, ofDividerAt: 0)
                }
                self.isSyncing = false
                self.suppressObservation = false
            }
        } else {
            if state.isVisible {
                sidebarSplitItem.isCollapsed = false
                splitView.setPosition(state.expandedWidth, ofDividerAt: 0)
            } else {
                sidebarSplitItem.isCollapsed = true
            }
            isSyncing = false
            suppressObservation = false
        }
    }

    /// Toolbar target that funnels through the shared model so every window in
    /// the group stays in sync.
    override func toggleSidebar(_ sender: Any?) {
        terminalController?.toggleProjectSidebar(sender)
    }
}

/// Builds the single native toolbar row for one project window:
/// `[traffic lights sidebar toggle] | [project tabs …][+]`.
///
/// - The toggle is a native circular button targeting
///   `ProjectSplitViewController.toggleSidebar`.
/// - The separator is an `NSTrackingSeparatorToolbarItem` bound to divider 0,
///   so it follows the sidebar divider with constraints, never
///   screen-coordinate offsets.
/// - The tab strip is the shared ``ProjectTabStripView`` in a flexible,
///   borderless item (`isBordered = false`); overflow scrolls inside the
///   strip while the toggle and strip keep high visibility priority at
///   minimum window widths.
/// - New Tab is a separate native, bordered toolbar item so AppKit owns its
///   sizing and glass bezel.
///
/// Toolbar identity is window-specific: each window gets its own delegate
/// instance (retained by its split controller) with autosave disabled, so
/// configuration never propagates to unrelated windows.
final class ProjectToolbarDelegate: NSObject, NSToolbarDelegate {
    static let sidebarToggleItemIdentifier = NSToolbarItem.Identifier("com.dar7an.toastty.sidebarToggle")
    static let tabStripItemIdentifier = NSToolbarItem.Identifier("com.dar7an.toastty.projectTabStrip")
    static let newTabItemIdentifier = NSToolbarItem.Identifier("com.dar7an.toastty.newTab")

    private weak var splitController: ProjectSplitViewController?
    private weak var terminalController: TerminalController?

    private var tabStripModel: TabSidebarModel?
    private var tabStripHostingView: NSHostingView<AnyView>?

    init(splitController: ProjectSplitViewController, controller: TerminalController?) {
        self.splitController = splitController
        self.terminalController = controller
        super.init()
    }

    /// Re-points the hosted tab strip at a new group model (e.g. after the
    /// tab moves groups). No-ops until the toolbar item is created.
    func updateTabStripModel(_ model: TabSidebarModel?) {
        tabStripModel = model
        refreshTabStrip()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.sidebarToggleItemIdentifier,
            .sidebarTrackingSeparator,
            Self.tabStripItemIdentifier,
            Self.newTabItemIdentifier,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    /// Creates the project toolbar items used for sidebar and tab controls.
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarToggleItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Toggle Sidebar"
            item.paletteLabel = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            item.target = splitController
            item.action = #selector(ProjectSplitViewController.toggleSidebar(_:))
            // Let AppKit draw the same circular toolbar bezel as New Tab.
            // Nesting a circular NSButton in a bordered toolbar item produces
            // a second, vertically stretched bezel on macOS 27.
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        case .sidebarTrackingSeparator:
            guard let splitView = splitController?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0)
        case Self.newTabItemIdentifier:
            // Use the same native toolbar sizing and glass bezel as Toggle
            // Sidebar. A SwiftUI button inside the tab strip has a different
            // control size and does not follow AppKit's toolbar metrics.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Tab"
            item.paletteLabel = "New Tab"
            if let shortcut = terminalController?.ghostty.config.keyboardShortcut(for: "new_tab") {
                item.toolTip = "New Tab (\(shortcut))"
            } else {
                item.toolTip = "New Tab"
            }
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
            item.target = terminalController
            item.action = #selector(TerminalController.newTab(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        case Self.tabStripItemIdentifier:
            let hosting: NSHostingView<AnyView>
            if let existing = tabStripHostingView {
                hosting = existing
            } else {
                hosting = ProjectTabStripHostingView(rootView: AnyView(tabStripView()))
                hosting.sizingOptions = []
                hosting.translatesAutoresizingMaskIntoConstraints = false
                hosting.setContentHuggingPriority(.defaultLow, for: .horizontal)
                hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                NSLayoutConstraint.activate([
                    hosting.widthAnchor.constraint(greaterThanOrEqualToConstant: 102),
                    hosting.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
                    hosting.heightAnchor.constraint(equalToConstant: ProjectTabStripView.stripHeight),
                ])
                tabStripHostingView = hosting
            }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Project Tabs"
            item.paletteLabel = "Project Tabs"
            item.view = hosting
            item.autovalidates = false
            item.isEnabled = true
            item.visibilityPriority = .high
            // The documented way to avoid the glass bezel on a custom-view item.
            item.isBordered = false
            return item
        default:
            return nil
        }
    }

    private func refreshTabStrip() {
        guard let hosting = tabStripHostingView else { return }
        hosting.rootView = AnyView(tabStripView())
    }

    /// Returns the current project tab strip, or an empty placeholder.
    private func tabStripView() -> some View {
        Group {
            if let model = tabStripModel {
                let controller = terminalController
                ProjectTabStripView(
                    model: model,
                    onSelect: { [weak model] in model?.select($0) },
                    shortcutHint: { [weak controller] index in
                        guard index < 9 else { return nil }
                        return controller?.ghostty.config.keyboardShortcut(for: "goto_tab:\(index + 1)")?.description
                    })
            } else {
                EmptyView()
            }
        }
    }
}
