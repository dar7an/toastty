import AppKit

/// Coordinates every move between the tab strip and the split tree.
///
/// Drop targets ask this type to calculate and commit operations instead of
/// mutating controllers directly. That keeps a preview and its eventual
/// mutation on the same code path and makes it possible to reject stale or
/// self-referential drags safely.
@MainActor
final class TerminalLayoutCoordinator {
    static let shared = TerminalLayoutCoordinator()

    private init() {}

    private struct ResolvedSource {
        let payload: TerminalLayoutDragPayload
        let controller: BaseTerminalController
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let tabController: TerminalController?

        var root: SplitTree<Ghostty.SurfaceView>.Node { node }
        var shape: TerminalLayoutShape { .init(node: node) }
    }

    // MARK: Public drop entry points

    /// Move a pane or a complete tab into an existing terminal pane.
    func move(
        payload: TerminalLayoutDragPayload,
        into destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        guard let destinationController = BaseTerminalController.controller(owning: destination),
              destinationController.surfaceTree.contains(destination) else { return }

        let target = TerminalLayoutDropTarget(
            destinationTabID: (destinationController as? TerminalController)?.projectTabID ?? destination.id,
            destinationSurfaceID: destination.id,
            intent: .split(zone))

        guard let proposal = makeProposal(
            payload: payload,
            target: target,
            destinationController: destinationController,
            destinationSurface: destination) else { return }

        commit(proposal, destinationController: destinationController, destinationSurface: destination)
    }

    /// Merge a complete tab into another tab. A nil destination surface means
    /// the root of the destination tree, which is used by a tab-cell drop.
    func moveTab(
        _ sourceTabID: UUID,
        into destinationTabID: UUID,
        destinationSurfaceID: UUID? = nil,
        zone: TerminalSplitDropZone = .right
    ) {
        guard let destinationController = controller(forTabID: destinationTabID) else { return }
        let destinationSurface = destinationSurfaceID.flatMap {
            destinationController.surfaceTree.find(id: $0)
        }.flatMap { node -> Ghostty.SurfaceView? in
            if case .leaf(let view) = node { return view }
            return nil
        }
        let target = TerminalLayoutDropTarget(
            destinationTabID: destinationTabID,
            destinationSurfaceID: destinationSurfaceID,
            intent: .split(zone))

        guard let proposal = makeProposal(
            payload: .tab(sourceTabID),
            target: target,
            destinationController: destinationController,
            destinationSurface: destinationSurface) else { return }

        commit(proposal, destinationController: destinationController, destinationSurface: destinationSurface)
    }

    /// Move one pane into the root or a particular pane of an existing tab.
    func moveSurface(
        _ surfaceID: UUID,
        into destinationTabID: UUID,
        destinationSurfaceID: UUID? = nil,
        zone: TerminalSplitDropZone = .right
    ) {
        guard let destinationController = controller(forTabID: destinationTabID) else { return }
        let destinationSurface = destinationSurfaceID.flatMap {
            destinationController.surfaceTree.find(id: $0)
        }.flatMap { node -> Ghostty.SurfaceView? in
            if case .leaf(let view) = node { return view }
            return nil
        }
        let target = TerminalLayoutDropTarget(
            destinationTabID: destinationTabID,
            destinationSurfaceID: destinationSurfaceID,
            intent: .split(zone))
        guard let proposal = makeProposal(
            payload: .surface(surfaceID),
            target: target,
            destinationController: destinationController,
            destinationSurface: destinationSurface) else { return }
        commit(proposal, destinationController: destinationController, destinationSurface: destinationSurface)
    }

    /// Extract one existing pane into a new tab in the destination tab's
    /// project and tab group.
    func extractSurface(
        _ surfaceID: UUID,
        beside destinationTabID: UUID,
        insertionIndex: Int? = nil
    ) {
        guard let destination = controller(forTabID: destinationTabID),
              let source = resolveSource(.surface(surfaceID)),
              let sourceWindow = source.controller.window,
              let destinationWindow = destination.window,
              source.controller.surfaceTree.isSplit,
              sourceWindow.tabGroup === destinationWindow.tabGroup
        else { return }

        guard source.controller.surfaceTree.contains(source.node) else { return }
        guard projectsMatch(source.controller, destination) else { return }

        let oldSourceTree = source.controller.surfaceTree
        let oldSourceFocus = source.controller.focusedSurface
        let newSourceTree = oldSourceTree.removing(source.node)

        // Create the new tab before removing the source node. If AppKit cannot
        // create the tab, the original layout is untouched.
        guard let extracted = TerminalController.newTab(
            destination.ghostty,
            from: destinationWindow,
            withSurfaceTree: .init(root: source.node, zoomed: nil),
            registerUndo: false,
            inProject: destination.project) else { return }

        guard let extractedWindow = extracted.window else { return }

        setTreeWithoutUndo(newSourceTree, on: source.controller)
        restoreFocus(oldSourceFocus, in: source.controller)

        if let insertionIndex {
            moveTabWindow(extractedWindow, in: destinationWindow, toProjectIndex: insertionIndex)
        }
        destinationWindow.tabGroup?.selectedWindow = extractedWindow
        extracted.focusedSurface = source.node.leftmostLeaf()
        Ghostty.moveFocus(to: source.node.leftmostLeaf(), from: oldSourceFocus)
        refreshTabModels(for: destinationWindow)

        registerSurfaceExtractionUndo(
            source: source.controller,
            sourceTree: oldSourceTree,
            sourceFocus: oldSourceFocus,
            extracted: extracted,
            destination: destination,
            insertionIndex: insertionIndex)
    }

    /// Reorder a tab using the same AppKit operation used by keyboard tab
    /// movement. The index is relative to the visible project tabs.
    func reorderTab(_ tabID: UUID, toProjectIndex targetIndex: Int) {
        guard let controller = controller(forTabID: tabID),
              let window = controller.window,
              window.tabGroup != nil else { return }

        let projectWindows = controller.projectTabWindows
        guard let currentIndex = projectWindows.firstIndex(of: window),
              projectWindows.count > 1 else { return }
        let clampedIndex = max(0, min(targetIndex, projectWindows.count - 1))
        guard clampedIndex != currentIndex else { return }

        let targetWindow = projectWindows[clampedIndex]
        let oldIndex = currentIndex
        moveTabWindow(window, in: targetWindow, toProjectIndex: clampedIndex)
        refreshTabModels(for: window)

        guard let undoManager = controller.undoManager else { return }
        undoManager.setActionName("Move Tab")
        undoManager.registerUndo(withTarget: self, expiresAfter: controller.undoExpiration) { coordinator in
            coordinator.reorderTab(tabID, toProjectIndex: oldIndex)
        }
    }

    /// Shared validation for rail previews and commits. Project identity and
    /// native tab-group membership must both match before showing a move.
    func canDropInTabBar(_ payload: TerminalLayoutDragPayload?, beside window: NSWindow) -> Bool {
        guard let payload, let source = resolveSource(payload),
              let target = window.windowController as? TerminalController,
              let sourceWindow = source.controller.window,
              sourceWindow.tabGroup != nil, sourceWindow.tabGroup === window.tabGroup,
              projectsMatch(source.controller, target) else { return false }
        switch payload {
        case .tab: return sourceWindow !== window
        case .surface: return source.controller.surfaceTree.isSplit
        }
    }

    // MARK: Proposal creation

    func proposal(
        for payload: TerminalLayoutDragPayload,
        on destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) -> TerminalLayoutDropProposal? {
        guard let destinationController = BaseTerminalController.controller(owning: destination) else { return nil }
        let target = TerminalLayoutDropTarget(
            destinationTabID: (destinationController as? TerminalController)?.projectTabID ?? destination.id,
            destinationSurfaceID: destination.id,
            intent: .split(zone))
        return makeProposal(
            payload: payload,
            target: target,
            destinationController: destinationController,
            destinationSurface: destination)
    }

    // MARK: Resolution

    private func controller(forTabID id: UUID) -> TerminalController? {
        // Closed source controllers can remain alive in AppKit/undo snapshots.
        // After undo, only the restored nonempty controller owns this tab ID.
        TerminalController.all.first {
            $0.projectTabID == id && !$0.surfaceTree.isEmpty && !$0.isWindowClosed
        }
    }

    private func resolveSource(_ payload: TerminalLayoutDragPayload) -> ResolvedSource? {
        switch payload {
        case .surface(let id):
            for controller in NSApp.windows.compactMap({ $0.windowController as? BaseTerminalController }) {
                if let node = controller.surfaceTree.find(id: id) {
                    return .init(payload: payload, controller: controller, node: node, tabController: controller as? TerminalController)
                }
            }
            return nil

        case .tab(let id):
            guard let controller = controller(forTabID: id), let root = controller.surfaceTree.root else { return nil }
            return .init(payload: payload, controller: controller, node: root, tabController: controller)
        }
    }

    private func makeProposal(
        payload: TerminalLayoutDragPayload,
        target: TerminalLayoutDropTarget,
        destinationController: BaseTerminalController,
        destinationSurface: Ghostty.SurfaceView?
    ) -> TerminalLayoutDropProposal? {
        guard let source = resolveSource(payload) else {
            return .invalid(payload: payload, target: target, rejection: .missingSource)
        }

        guard let destinationTree = destinationController.surfaceTree.root else {
            return .invalid(payload: payload, target: target, sourceShape: source.shape, rejection: .missingDestination)
        }

        let destinationTab = destinationController as? TerminalController
        if let destinationTab {
            guard destinationTab.projectTabID == target.destinationTabID else {
                return .invalid(
                    payload: payload,
                    target: target,
                    sourceShape: source.shape,
                    destinationShape: .init(node: destinationTree),
                    rejection: .invalidTarget)
            }
        } else if destinationSurface == nil {
            return .invalid(
                payload: payload,
                target: target,
                sourceShape: source.shape,
                destinationShape: .init(node: destinationTree),
                rejection: .invalidTarget)
        }

        if case .tab = payload, destinationTab == nil {
            return .invalid(payload: payload, target: target, rejection: .invalidTarget)
        }
        if source.controller is TerminalController, destinationTab == nil,
           source.controller.surfaceTree.count == 1 {
            return .invalid(payload: payload, target: target, rejection: .invalidTarget)
        }

        if source.controller === destinationController {
            if case .tab = payload {
                return .invalid(
                    payload: payload,
                    target: target,
                    sourceShape: source.shape,
                    destinationShape: .init(node: destinationTree),
                    rejection: .sameTab)
            }
            if let destinationSurface, source.controller.surfaceTree.contains(source.node), source.node.contains(where: { $0 === destinationSurface }) {
                return .invalid(
                    payload: payload,
                    target: target,
                    sourceShape: source.shape,
                    destinationShape: .init(node: destinationTree),
                    rejection: .sourceContainsDestination)
            }
        }

        if let sourceTab = source.tabController,
           let destinationTab,
           sourceTab !== destinationTab,
           !projectsMatch(sourceTab, destinationTab) {
            return .invalid(
                payload: payload,
                target: target,
                sourceShape: source.shape,
                destinationShape: .init(node: destinationTree),
                rejection: .unsupportedProject)
        }

        guard case .split(let zone) = target.intent else {
            return .invalid(
                payload: payload,
                target: target,
                sourceShape: source.shape,
                destinationShape: .init(node: destinationTree),
                rejection: .invalidTarget)
        }

        let destinationNode: SplitTree<Ghostty.SurfaceView>.Node
        if let destinationSurface {
            guard let found = destinationController.surfaceTree.find(id: destinationSurface.id) else {
                return .invalid(
                    payload: payload,
                    target: target,
                    sourceShape: source.shape,
                    destinationShape: .init(node: destinationTree),
                    rejection: .missingDestination)
            }
            destinationNode = found
        } else {
            destinationNode = destinationTree
        }

        let resultTree: SplitTree<Ghostty.SurfaceView>
        do {
            if source.controller === destinationController {
                let withoutSource = destinationController.surfaceTree.removing(source.node)
                guard let remainingRoot = withoutSource.root,
                      withoutSource.contains(destinationNode) else {
                    return .invalid(
                        payload: payload,
                        target: target,
                        sourceShape: source.shape,
                        destinationShape: .init(node: destinationTree),
                        rejection: .invalidTarget)
                }
                resultTree = try withoutSource.inserting(
                    node: source.node,
                    at: remainingRoot == destinationNode ? remainingRoot : destinationNode,
                    direction: zone.newDirection)
            } else {
                resultTree = try destinationController.surfaceTree.inserting(
                    node: source.node,
                    at: destinationNode,
                    direction: zone.newDirection)
            }
        } catch {
            return .invalid(
                payload: payload,
                target: target,
                sourceShape: source.shape,
                destinationShape: .init(node: destinationTree),
                rejection: .invalidTarget)
        }

        let resultShape = resultTree.root.map(TerminalLayoutShape.init)
        let sourceShape = source.shape
        let destinationShape = TerminalLayoutShape(node: destinationTree)
        _ = destinationController // Keep the validation explicit for callers.
        return .init(
            payload: payload,
            target: target,
            sourceShape: sourceShape,
            destinationShape: destinationShape,
            resultShape: resultShape,
            isValid: true,
            rejection: nil)
    }

    // MARK: Commit

    private func commit(
        _ proposal: TerminalLayoutDropProposal,
        destinationController: BaseTerminalController,
        destinationSurface: Ghostty.SurfaceView?
    ) {
        guard proposal.isValid,
              case .split(let zone) = proposal.target.intent,
              let source = resolveSource(proposal.payload),
              let destinationRoot = destinationController.surfaceTree.root else { return }

        let destinationNode = destinationSurface.flatMap {
            destinationController.surfaceTree.find(id: $0.id)
        } ?? destinationRoot

        if case .tab(let sourceTabID) = proposal.payload {
            guard let sourceTab = source.tabController,
                  let destinationTab = destinationController as? TerminalController,
                  sourceTab !== destinationTab else { return }
            commitTabMove(
                source: sourceTab,
                destination: destinationTab,
                destinationNode: destinationNode,
                destinationSurfaceID: proposal.target.destinationSurfaceID,
                zone: zone)
            _ = sourceTabID
            return
        }

        guard case .surface(let surfaceID) = proposal.payload,
              let sourceSurface = source.controller.surfaceTree.first(where: { $0.id == surfaceID }) else { return }
        commitSurfaceMove(
            source: source.controller,
            sourceNode: source.node,
            sourceSurface: sourceSurface,
            destination: destinationController,
            destinationNode: destinationNode,
            zone: zone)
    }

    private func commitSurfaceMove(
        source: BaseTerminalController,
        sourceNode: SplitTree<Ghostty.SurfaceView>.Node,
        sourceSurface: Ghostty.SurfaceView,
        destination: BaseTerminalController,
        destinationNode: SplitTree<Ghostty.SurfaceView>.Node,
        zone: TerminalSplitDropZone
    ) {
        guard source !== destination else {
            let oldTree = source.surfaceTree
            let oldFocus = source.focusedSurface
            let withoutSource = oldTree.removing(sourceNode)
            guard let destinationRoot = withoutSource.root,
                  let newTree = try? withoutSource.inserting(
                    node: sourceNode,
                    at: destinationRoot == destinationNode ? destinationRoot : destinationNode,
                    direction: zone.newDirection) else { return }
            source.replaceSurfaceTree(newTree, moveFocusTo: sourceSurface, moveFocusFrom: oldFocus, undoAction: "Move Split")
            return
        }

        // Moving the last pane is a complete tab transfer. Reuse that
        // transaction so the empty source closes and Undo restores its tab.
        if source.surfaceTree.count == 1,
           let sourceTab = source as? TerminalController,
           let destinationTab = destination as? TerminalController {
            commitTabMove(
                source: sourceTab, destination: destinationTab,
                destinationNode: destinationNode,
                destinationSurfaceID: destinationNode.leftmostLeaf().id, zone: zone)
            return
        }

        guard let newDestinationTree = try? destination.surfaceTree.inserting(
            node: sourceNode,
            at: destinationNode,
            direction: zone.newDirection) else { return }

        let oldSourceTree = source.surfaceTree
        let oldDestinationTree = destination.surfaceTree
        let oldSourceFocus = source.focusedSurface
        let oldDestinationFocus = destination.focusedSurface

        setTreeWithoutUndo(newDestinationTree, on: destination)
        removeNodeWithoutUndo(sourceNode, from: source)
        destination.focusedSurface = sourceSurface
        Ghostty.moveFocus(to: sourceSurface, from: oldDestinationFocus)

        registerSurfaceMoveUndo(
            sourceState: .init(controller: source, tree: oldSourceTree, focus: oldSourceFocus),
            destinationState: .init(controller: destination, tree: oldDestinationTree, focus: oldDestinationFocus),
            sourceSurfaceID: sourceSurface.id,
            destinationSurfaceID: destinationNode.leftmostLeaf().id,
            zone: zone)
    }

    private func commitTabMove(
        source: TerminalController,
        destination: TerminalController,
        destinationNode: SplitTree<Ghostty.SurfaceView>.Node,
        destinationSurfaceID: UUID?,
        zone: TerminalSplitDropZone
    ) {
        guard let sourceWindow = source.window,
              let destinationWindow = destination.window,
              sourceWindow !== destinationWindow,
              projectsMatch(source, destination),
              let sourceRoot = source.surfaceTree.root,
              let newDestinationTree = try? destination.surfaceTree.inserting(
                node: sourceRoot,
                at: destinationNode,
                direction: zone.newDirection),
              let sourceState = source.undoState else { return }

        let oldDestinationTree = destination.surfaceTree
        let oldDestinationFocus = destination.focusedSurface
        let sourceFocus = source.focusedSurface
        let sourceTabID = source.projectTabID
        let destinationTabID = destination.projectTabID

        // Assign the destination first. This updates the weak surface-owner
        // table before the source is emptied.
        setTreeWithoutUndo(newDestinationTree, on: destination)
        source.replaceSurfaceTreeForLayoutTransfer(.init())
        source.closeForLayoutTransfer()

        destinationWindow.tabGroup?.selectedWindow = destinationWindow
        if let sourceFocus {
            destination.focusedSurface = sourceFocus
            Ghostty.moveFocus(to: sourceFocus, from: oldDestinationFocus)
        }
        refreshTabModels(for: destinationWindow)

        guard let undoManager = destination.undoManager else { return }
        let ghostty = destination.ghostty
        let coordinator = self
        undoManager.setActionName("Move Tab into Split")
        undoManager.registerUndo(withTarget: destination, expiresAfter: destination.undoExpiration) { _ in
            // The source is recreated from its snapshot, but the destination
            // restore only makes sense while its window is still open.
            guard let destination = coordinator.controller(forTabID: destinationTabID),
                  !destination.isWindowClosed else { return }

            coordinator.setTreeWithoutUndo(oldDestinationTree, on: destination)
            let restoredSource = TerminalController(ghostty, with: sourceState)
            destination.window?.tabGroup?.selectedWindow = destination.window
            coordinator.restoreFocus(oldDestinationFocus, in: destination)
            coordinator.refreshTabModels(for: destination.window)

            destination.undoManager?.registerUndo(
                withTarget: destination, expiresAfter: destination.undoExpiration
            ) { _ in
                coordinator.moveTab(
                    sourceTabID,
                    into: destinationTabID,
                    destinationSurfaceID: destinationSurfaceID,
                    zone: zone)
            }
            _ = restoredSource
        }
    }

    // MARK: Undo helpers

    private struct LayoutSnapshot {
        let controller: BaseTerminalController
        let tree: SplitTree<Ghostty.SurfaceView>
        let focus: Ghostty.SurfaceView?
    }

    private func registerSurfaceMoveUndo(
        sourceState: LayoutSnapshot,
        destinationState: LayoutSnapshot,
        sourceSurfaceID: UUID,
        destinationSurfaceID: UUID,
        zone: TerminalSplitDropZone
    ) {
        let source = sourceState.controller
        let destination = destinationState.controller
        guard let undoManager = destination.undoManager else { return }
        let sourceTree = sourceState.tree
        let sourceFocus = sourceState.focus
        let destinationTree = destinationState.tree
        let destinationFocus = destinationState.focus
        let coordinator = self
        undoManager.setActionName("Move Split")
        // The undo manager retains the handler while only the proxy target
        // is held weakly, so target a participating controller and capture
        // the source weakly: a closed window must drop or skip the action.
        undoManager.registerUndo(withTarget: destination, expiresAfter: destination.undoExpiration) { [weak source] destination in
            // Mutating either tree only makes sense while both windows are
            // open: restoring a closed source is invisible, and restoring
            // the destination alone drops the moved surface entirely.
            guard let source, !source.isWindowClosed, !destination.isWindowClosed
            else { return }
            coordinator.setTreeWithoutUndo(sourceTree, on: source)
            coordinator.setTreeWithoutUndo(destinationTree, on: destination)
            coordinator.restoreFocus(sourceFocus, in: source)
            coordinator.restoreFocus(destinationFocus, in: destination)
            coordinator.refreshTabModels(for: destination.window)

            destination.undoManager?.registerUndo(
                withTarget: destination, expiresAfter: destination.undoExpiration
            ) { [weak source] destination in
                guard let source, !source.isWindowClosed,
                      let sourceSurface = source.surfaceTree.first(where: { $0.id == sourceSurfaceID }),
                      let destinationSurface = destination.surfaceTree.first(where: { $0.id == destinationSurfaceID }) else { return }
                coordinator.commitSurfaceMove(
                    source: source,
                    sourceNode: .leaf(view: sourceSurface),
                    sourceSurface: sourceSurface,
                    destination: destination,
                    destinationNode: .leaf(view: destinationSurface),
                    zone: zone)
            }
        }
    }

    private func registerSurfaceExtractionUndo(
        source: BaseTerminalController,
        sourceTree: SplitTree<Ghostty.SurfaceView>,
        sourceFocus: Ghostty.SurfaceView?,
        extracted: TerminalController,
        destination: TerminalController,
        insertionIndex: Int?
    ) {
        guard let undoManager = destination.undoManager else { return }
        let extractedID = extracted.projectTabID
        let surfaceID = extracted.surfaceTree.first?.id
        let coordinator = self
        undoManager.setActionName("Extract Split to Tab")
        undoManager.registerUndo(withTarget: destination, expiresAfter: destination.undoExpiration) { [weak source] destination in
            // Putting the surface back requires the source window: if it
            // closed, closing the extracted tab would lose the surface.
            guard let source, !source.isWindowClosed, !destination.isWindowClosed,
                  let surfaceID,
                  let extracted = coordinator.controller(forTabID: extractedID) else { return }
            let extractedSurface = extracted.surfaceTree.first(where: { $0.id == surfaceID })
            guard let extractedSurface else { return }

            coordinator.setTreeWithoutUndo(sourceTree, on: source)
            coordinator.restoreFocus(sourceFocus, in: source)
            extracted.replaceSurfaceTreeForLayoutTransfer(.init())
            extracted.closeForLayoutTransfer()
            coordinator.refreshTabModels(for: destination.window)

            destination.undoManager?.registerUndo(
                withTarget: destination, expiresAfter: destination.undoExpiration
            ) { destination in
                coordinator.extractSurface(
                    surfaceID,
                    beside: destination.projectTabID,
                    insertionIndex: insertionIndex)
            }
        }
    }

    // MARK: Controller and AppKit helpers

    private func setTreeWithoutUndo(
        _ tree: SplitTree<Ghostty.SurfaceView>,
        on controller: BaseTerminalController
    ) {
        if let terminal = controller as? TerminalController {
            terminal.replaceSurfaceTreeForLayoutTransfer(tree)
        } else {
            controller.surfaceTree = tree
        }
    }

    private func removeNodeWithoutUndo(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        from controller: BaseTerminalController
    ) {
        controller.removeSurfaceNodeForLayoutTransfer(node)
    }

    private func restoreFocus(
        _ surface: Ghostty.SurfaceView?,
        in controller: BaseTerminalController
    ) {
        guard let surface, controller.surfaceTree.contains(surface) else {
            controller.focusedSurface = controller.surfaceTree.first
            return
        }
        controller.focusedSurface = surface
        Ghostty.moveFocus(to: surface, from: nil)
    }

    private func refreshTabModels(for window: NSWindow?) {
        guard let window else { return }
        window.tabGroup?.tabSidebarModel.refresh()
        if let controller = window.windowController as? TerminalController {
            controller.relabelTabs()
        }
    }

    private func moveTabWindow(
        _ window: NSWindow,
        in anchor: NSWindow,
        toProjectIndex targetIndex: Int
    ) {
        guard let tabGroup = anchor.tabGroup,
              let controller = anchor.windowController as? TerminalController else { return }
        let windows = controller.projectTabWindows
        guard let currentIndex = windows.firstIndex(of: window),
              windows.count > 1 else { return }
        let clampedIndex = max(0, min(targetIndex, windows.count - 1))
        guard clampedIndex != currentIndex else { return }
        let targetWindow = windows[clampedIndex]
        let selectedWindow = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(window)
        targetWindow.addTabbedWindowSafely(
            window,
            ordered: clampedIndex < currentIndex ? .below : .above)
        (selectedWindow ?? window).makeKey()
        NSAnimationContext.endGrouping()
    }
    private func projectsMatch(
        _ left: BaseTerminalController,
        _ right: TerminalController
    ) -> Bool {
        guard let left = left as? TerminalController else { return false }
        return left.project.id == right.project.id
    }

    private func projectsMatch(
        _ left: TerminalController,
        _ right: TerminalController
    ) -> Bool {
        left.project.id == right.project.id
    }
}
