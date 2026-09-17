import AppKit
import Combine
import SwiftUI

/// Native AppKit composition for the project sidebar and toolbar.
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

    private var model: TabSidebarModel?
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
              window.tabGroup?.selectedWindow === window else { return }
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
        modelCancellable = nil
        self.model = model
        guard let model, let controller = terminalController else { return }
        pendingInitialState = model.sidebarState
        controller.sidebarState = model.sidebarState
        sidebarHostingController.rootView = AnyView(
            ProjectSidebarListView(model: model, controller: controller))
        toolbarDelegate?.updateTabStripModel(model)
        modelCancellable = model.$sidebarState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.terminalController?.sidebarState = state
                self.applySidebarState(state, animated: true)
            }
        applySidebarState(model.sidebarState, animated: animated)
    }

    /// Observes AppKit tab-group membership so a tab dragged into another
    /// group adopts the destination group's sidebar state. The group bound
    /// by `bind(to:animated:)` is skipped to avoid re-applying on load.
    func beginObservingTabGroup() {
        guard let controller = terminalController else { return }
        var lastGroupID: ObjectIdentifier? = controller.window?.tabGroup.map(ObjectIdentifier.init)
        windowCancellable = controller.publisher(for: \.window)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] window in
                guard let self else { return }
                guard let window else {
                    self.tabGroupCancellable = nil
                    return
                }
                self.tabGroupCancellable = window.publisher(for: \.tabGroup)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] group in
                        guard let self else { return }
                        let groupID = group.map(ObjectIdentifier.init)
                        if groupID != lastGroupID {
                            lastGroupID = groupID
                            self.bind(to: group?.tabSidebarModel, animated: false)
                        }
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
        let animate = animated && !reduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { [self] _ in
                if state.isVisible {
                    sidebarSplitItem.animator().isCollapsed = false
                    splitView.animator().setPosition(state.expandedWidth, ofDividerAt: 0)
                } else {
                    sidebarSplitItem.animator().isCollapsed = true
                }
            } completionHandler: { [weak self] in
                guard let self, self.animationGeneration == generation else { return }
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

    /// Standard responder-chain target for the toolbar's `.toggleSidebar`
    /// item. Funnels through the shared model so every window in the group
    /// stays in sync (unlike the default item behavior).
    override func toggleSidebar(_ sender: Any?) {
        terminalController?.toggleProjectSidebar(sender)
    }
}
