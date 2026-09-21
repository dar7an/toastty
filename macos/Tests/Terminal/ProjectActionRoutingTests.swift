import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct ProjectActionRoutingTests {
    /// Verifies that project bindings remain printable in unsupported windows.
    @Test(arguments: [false, true])
    func unsupportedWindowsPreserveOptionDigitInput(nativeTabs: Bool) async throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let surface = try #require(view.surface)
        // Quick Terminal uses BaseTerminalController; native-tab windows use
        // TerminalController with projects disabled. Exercise both dispatch paths.
        let controller: BaseTerminalController = nativeTabs
            ? TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: false)
            : BaseTerminalController(app, surfaceTree: .init(view: view))
        let window = makeWindow(controller, views: [view])
        defer { tearDown(controller, window: window) }
        controller.focusedSurface = view

        for action in ["new_project", "goto_project:1", "toggle_project_sidebar"] {
            #expect(!ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)))
        }
        var event = optionDigitEvent()
        "¡".withCString { text in
            event.text = text
            _ = ghostty_surface_key(surface, event)
            event.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, event)
        }
        // Also exercise AppKit text interpretation, not only the C key API.
        let nativeEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "™", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 0x13))
        view.keyDown(with: nativeEvent)
        // Check PTY echo, not just the flags or action callback's return value.
        for _ in 0..<100 {
            let text = screenText(surface)
            if text.contains("¡") && text.contains("™") { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Option+1 was swallowed instead of reaching the terminal")
    }

    @Test func projectPaletteHasOneCreationCommandAndNoForeignWindowFallback() throws {
        let app = try Self.testApp()
        let core = try #require(app.app)
        let view = Ghostty.SurfaceView(core)
        let controller = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(controller, views: [view])
        defer { tearDown(controller, window: window) }
        let palette = TerminalCommandPaletteView(
            surfaceView: view, isPresented: .constant(true), ghosttyConfig: app.config, onAction: { _ in })
        #expect(palette.commandOptions.filter { $0.title == "New Project" }.count == 1)
        #expect(palette.commandOptions.filter { $0.title == "Toggle Project Sidebar" }.count == 1)
        #expect(palette.commandOptions.contains { $0.title == "Rename Project…" })
        #expect(palette.commandOptions.filter { $0.title.hasPrefix("Appearance:") }.map(\.title) == [
            "Appearance: Dark", "Appearance: Light", "Appearance: System"
        ])

        let quickView = Ghostty.SurfaceView(core)
        let quick = BaseTerminalController(app, surfaceTree: .init(view: quickView))
        let quickWindow = makeWindow(quick, views: [quickView])
        defer { tearDown(quick, window: quickWindow) }
        let quickPalette = TerminalCommandPaletteView(
            surfaceView: quickView, isPresented: .constant(true), ghosttyConfig: app.config, onAction: { _ in })
        #expect(!quickPalette.commandOptions.contains { $0.title.contains("Project") || $0.title.contains("Sidebar") })
        #expect(quickPalette.commandOptions.filter { $0.title.hasPrefix("Appearance:") }.count == 3)
    }

    @Test func moveAndCloseClickedPanePreserveSurfacesAndUndo() async throws {
        let app = try Self.testApp()
        let core = try #require(app.app)
        let first = Ghostty.SurfaceView(core)
        let second = Ghostty.SurfaceView(core)
        let tree = try SplitTree(view: first).inserting(view: second, at: first, direction: .right)
        let controller = PaneTestController(app, surfaceTree: tree)
        let window = makeWindow(controller, views: [first, second])
        defer { tearDown(controller, window: window) }
        controller.focusedSurface = second
        let undo = controller.testUndoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        first.moveSplitRightFromMenu(nil)
        undo.endUndoGrouping()
        #expect(Array(controller.surfaceTree).map(\.id) == [second.id, first.id])
        #expect(undo.undoActionName == "Move Split")
        undo.undo()
        await drainMainQueue()
        #expect(Array(controller.surfaceTree).map(\.id) == [first.id, second.id])
        undo.removeAllActions()

        // The request-close callback is delivered on the main queue.
        controller.focusedSurface = second
        undo.beginUndoGrouping()
        first.closeSplitFromMenu(nil)
        for _ in 0..<20 where controller.surfaceTree.contains(first) {
            await Task.yield()
        }
        undo.endUndoGrouping()
        #expect(!controller.surfaceTree.contains(first))
        #expect(controller.surfaceTree.contains(second))
        #expect(controller.focusedSurface === second)
        #expect(undo.undoActionName == "Close Split")
        undo.undo()
        await drainMainQueue()
        #expect(Array(controller.surfaceTree).map(\.id) == [first.id, second.id])
        #expect(window.firstResponder === second)
    }

    @Test func paletteDismissalPreservesProjectRenameFocus() throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let controller = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(controller, views: [view])
        window.tabbingMode = .preferred
        defer { tearDown(controller, window: window) }
        window.makeKeyAndOrderFront(nil)
        let model = try #require(window.tabGroup?.tabSidebarModel)
        model.beginRename(projectID: controller.project.id)
        let field = NSTextField(string: "Rename remains active")
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = window.firstResponder
        restoreTerminalFocusAfterPalette(view)
        #expect(window.firstResponder === editor)
        #expect(window.firstResponder !== view)
    }

    @Test func newTabsHaveProjectStateBeforeTheirFirstRender() async throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let parent = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(parent, views: [view])
        window.tabbingMode = .preferred
        parent.project = TerminalProject(name: "Workspace", directory: "/tmp")
        defer { tearDown(parent, window: window) }
        let tabGroup = try #require(window.tabGroup)
        tabGroup.selectedWindow = window
        let model = tabGroup.tabSidebarModel
        var selectedWithTerminalFocus = false
        let selectionObservation = tabGroup.observe(\.selectedWindow, options: [.new]) { _, change in
            guard let selected = change.newValue as? NSWindow,
                  let controller = selected.windowController as? TerminalController else { return }
            selectedWithTerminalFocus = selected.firstResponder === controller.focusedSurface
        }
        defer { selectionObservation.invalidate() }
        // Deliberately do not drain the main queue: this is the first frame.
        #expect(model.projects.map(\.id) == [parent.project.id])
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        defer { tearDown(tab, window: tabWindow) }
        #expect(tabWindow.tabGroup === window.tabGroup)
        #expect(selectedWithTerminalFocus)
        #expect(model.rows.count == 2)
        #expect(model.projects.map(\.id) == [parent.project.id])
        #expect(model.editingProjectID == nil)
        #expect(model.editingProjectEmojiID == nil)
        await drainMainQueue()
        let split = try #require((tabWindow.contentView as? TerminalViewContainer)?.projectSplitViewController)
        #expect(split.model === tabWindow.tabGroup?.tabSidebarModel)
        #expect(split.model?.projects.map(\.id) == [parent.project.id])
    }

    @Test func rapidlyCreatedTabsPopulateTheSharedStrip() async throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let parent = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(parent, views: [view])
        window.tabbingMode = .preferred
        var tabs: [TerminalController] = []
        defer {
            for tab in tabs.reversed() {
                if let tabWindow = tab.window { tearDown(tab, window: tabWindow) }
            }
            tearDown(parent, window: window)
        }
        let model = try #require(window.tabGroup?.tabSidebarModel)
        for _ in 0..<9 {
            tabs.append(try #require(
                TerminalController.newTab(app, from: window, registerUndo: false)))
        }
        #expect(model.rows.count == 10)

        await drainMainQueue()
        let selectedWindow = try #require(window.tabGroup?.selectedWindow)
        selectedWindow.contentView?.layoutSubtreeIfNeeded()
        let strip = try #require(selectedWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        func cells(in view: NSView) -> [ProjectTabCellHostingView] {
            view.subviews.flatMap { ($0 as? ProjectTabCellHostingView).map { [$0] } ?? cells(in: $0) }
        }
        #expect(cells(in: strip).count == 10)
    }

    @Test func nativeTabDragPreviewsThenCommitsOneReorder() async throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let parent = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(parent, views: [view])
        window.tabbingMode = .preferred
        defer { tearDown(parent, window: window) }
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        defer { tearDown(tab, window: tabWindow) }
        tabWindow.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let strip = try #require(tabWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        func cells(in view: NSView) -> [ProjectTabCellHostingView] {
            view.subviews.flatMap { ($0 as? ProjectTabCellHostingView).map { [$0] } ?? cells(in: $0) }
        }
        let cell = try #require(cells(in: strip).first { $0.rootView.row.window === window })
        let targetCell = try #require(cells(in: strip).first { $0.rootView.row.window === tabWindow })
        #expect(cell.bounds.width > 0)
        let selectedWindow = tabWindow.tabGroup?.selectedWindow
        let preview = try #require(ProjectTabReorderGesture(source: cell))
        let reorderTranslation = (cell.bounds.width + targetCell.bounds.width) / 2 + 1
        preview.update(translation: reorderTranslation)
        #expect(preview.targetIndex == 1)
        #expect(window.tabGroup?.windows == [window, tabWindow])
        preview.finish(commit: false, animated: false)
        #expect(window.tabGroup?.windows == [window, tabWindow])

        let start = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + reorderTranslation, y: start.y)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: tabWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        cell.mouseDown(with: try event(.leftMouseDown, start))
        cell.mouseDragged(with: try event(.leftMouseDragged, end))
        #expect(window.tabGroup?.windows == [window, tabWindow])
        cell.mouseUp(with: try event(.leftMouseUp, end))
        await drainMainQueue()
        #expect(window.tabGroup?.windows == [tabWindow, window])
        #expect(tabWindow.tabGroup?.selectedWindow === selectedWindow)
        #expect((tabWindow.contentView as? TerminalViewContainer)?.projectSplitViewController?.model?.projects.count == 1)
    }

    @Test(arguments: [false, true])
    func liftedTabDropsIntoNeighborAsSplitWithoutLosingSurfaces(detached: Bool) async throws {
        let app = try Self.testApp()
        let view = Ghostty.SurfaceView(try #require(app.app))
        let controller = TerminalController(app, withSurfaceTree: .init(view: view), usesProjectSidebar: true)
        let window = makeWindow(controller, views: [view])
        window.tabbingMode = .preferred
        window.orderFront(nil)
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        defer {
            tearDown(tab, window: tabWindow)
            tearDown(controller, window: window)
        }
        await drainMainQueue()
        let sourceIDs = tab.surfaceTree.map(\.id)
        let destination = try #require(controller.surfaceTree.root?.leftmostLeaf())
        let strip = try #require(tabWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let cell = try #require(descendants(of: strip).compactMap { $0 as? ProjectTabCellHostingView }
            .first { $0.rootView.row.window === tabWindow })
        if detached {
            #expect(cell.detachForWindowDrag())
            await drainMainQueue()
            // Rail reorder is group-local; split transfers retain the shared
            // coordinator's existing same-project, cross-window behavior.
            #expect(!TerminalLayoutCoordinator.shared.canDropInTabBar(.tab(tab.projectTabID), beside: window))
        }
        let drag = ProjectTabDragSession(source: cell, grabPoint: NSPoint(x: cell.bounds.midX, y: 14))
        drag.lift()
        await drainMainQueue()
        // Resolve a screen-space drop against the visible pane after
        // selection changes, and retain the live terminal surfaces.
        view.frame = try #require(window.contentView).bounds
        let point = window.convertPoint(toScreen: view.convert(
            NSPoint(x: view.bounds.maxX - 20, y: view.bounds.midY), to: nil))
        #expect(drag.commitDrop(at: point, in: window))
        drag.finish(accepted: true, detach: false, at: .zero)
        await drainMainQueue()
        #expect(controller.surfaceTree.count == sourceIDs.count + 1)
        #expect(sourceIDs.allSatisfy { controller.surfaceTree.find(id: $0) != nil })
        #expect(controller.surfaceTree.contains(destination))
        #expect(tab.surfaceTree.isEmpty)
        #expect(window.projectSidebarModel.liftedTabID == nil)
    }

    @Test func layoutTransferClosesLastPaneSourceAndRestoresItOnUndo() async throws {
        let app = try Self.testApp()
        let core = try #require(app.app)
        let first = Ghostty.SurfaceView(core)
        let second = Ghostty.SurfaceView(core)
        let source = TerminalController(app, withSurfaceTree: .init(view: first), usesProjectSidebar: true)
        let target = LayoutTestController(app, withSurfaceTree: .init(view: second), usesProjectSidebar: true)
        let sourceWindow = makeWindow(source, views: [first])
        let targetWindow = makeWindow(target, views: [second])
        sourceWindow.tabbingMode = .preferred
        targetWindow.tabbingMode = .preferred
        target.project = source.project
        sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
        source.focusedSurface = first
        target.focusedSurface = second
        let sourceID = source.projectTabID
        defer {
            target.testUndoManager.removeAllActions()
            for restored in TerminalController.all where restored.projectTabID == sourceID && restored !== source {
                if let window = restored.window { tearDown(restored, window: window) }
            }
            tearDown(source, window: sourceWindow)
            tearDown(target, window: targetWindow)
        }
        let coordinator = TerminalLayoutCoordinator.shared
        #expect(coordinator.proposal(for: .surface(first.id), on: first, zone: .right)?.isValid == false)
        #expect(coordinator.canDropInTabBar(.surface(first.id), beside: targetWindow) == false)
        let project = target.project
        target.project = TerminalProject(directory: "/another-project")
        #expect(coordinator.proposal(for: .surface(first.id), on: second, zone: .right)?.isValid == false)
        target.project = project
        #expect(coordinator.proposal(for: .surface(first.id), on: second, zone: .right)?.isValid == true)
        let undo = target.testUndoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        coordinator.move(payload: .surface(first.id), into: second, zone: .right)
        undo.endUndoGrouping()
        #expect(source.surfaceTree.isEmpty)
        #expect(target.surfaceTree.count == 2)
        #expect(!sourceWindow.isVisible)
        #expect(targetWindow.tabGroup?.windows.contains(sourceWindow) != true)
        undo.undo()
        await drainMainQueue()
        let restored = try #require(TerminalController.all.first { $0.projectTabID == sourceID && $0 !== source })
        #expect(restored.surfaceTree.contains(first))
        #expect(restored.project.id == project.id)
        #expect(target.surfaceTree.count == 1)
        #expect(target.surfaceTree.contains(second))
        undo.redo()
        await drainMainQueue()
        #expect(target.surfaceTree.count == 2)
    }

    @Test func moveUndoSkipsWhenSourceWindowClosed() async throws {
        let app = try Self.testApp()
        let core = try #require(app.app)
        let first = Ghostty.SurfaceView(core)
        let second = Ghostty.SurfaceView(core)
        let extra = Ghostty.SurfaceView(core)
        // A two-pane source keeps its window open when one pane moves away.
        let sourceTree = try SplitTree(view: first).inserting(view: extra, at: first, direction: .right)
        let source = LayoutTestController(app, withSurfaceTree: sourceTree, usesProjectSidebar: true)
        let target = LayoutTestController(app, withSurfaceTree: .init(view: second), usesProjectSidebar: true)
        let sourceWindow = makeWindow(source, views: [first, extra])
        let targetWindow = makeWindow(target, views: [second])
        sourceWindow.tabbingMode = .preferred
        targetWindow.tabbingMode = .preferred
        target.project = source.project
        sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
        defer {
            target.testUndoManager.removeAllActions()
            tearDown(source, window: sourceWindow)
            tearDown(target, window: targetWindow)
        }
        let undo = target.testUndoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        TerminalLayoutCoordinator.shared.move(payload: .surface(extra.id), into: second, zone: .right)
        undo.endUndoGrouping()
        #expect(target.surfaceTree.count == 2)
        #expect(target.surfaceTree.contains(extra))
        #expect(source.surfaceTree.count == 1)

        // The undo manager retains its handler, so a closed source window
        // does not remove the action. Running it must skip both restores:
        // the destination restore alone would drop the moved surface while
        // the source restore lands in a dead window.
        sourceWindow.close()
        undo.undo()
        await drainMainQueue()
        #expect(target.surfaceTree.count == 2)
        #expect(target.surfaceTree.contains(extra))
    }

    private func drainMainQueue() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    // Match the production lifetime: one libghostty app outlives every view,
    // including AppKit's autoreleased views and deferred focus callbacks.
    private static var sharedApp: Ghostty.App?
    private static var sharedConfig: TemporaryConfig?

    private static func testApp() throws -> Ghostty.App {
        if let sharedApp { return sharedApp }
        let config = try TemporaryConfig("shell-integration = none\ncommand = /bin/cat\nmacos-option-as-alt = false\nconfirm-close-surface = false")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        sharedConfig = config
        sharedApp = app
        return app
    }

    private func makeWindow(_ controller: BaseTerminalController, views: [Ghostty.SurfaceView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        controller.window = window
        // Production nibs wire the controller as the window delegate; mirror
        // that here so close lifecycle hooks (windowWillClose) fire in tests.
        window.delegate = controller
        for view in views { window.contentView?.addSubview(view) }
        return window
    }

    private func tearDown(_ controller: BaseTerminalController, window: NSWindow) {
        controller.undoManager?.removeAllActions(withTarget: controller)
        controller.focusedSurface = nil
        controller.surfaceTree = .init()
        window.contentView = nil
        controller.window = nil
        window.close()
    }

    private func optionDigitEvent() -> ghostty_input_key_s {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = 0x12
        event.mods = GHOSTTY_MODS_ALT
        event.consumed_mods = GHOSTTY_MODS_ALT
        event.unshifted_codepoint = 49
        return event
    }

    private func screenText(_ surface: ghostty_surface_t) -> String {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}

private final class PaneTestController: BaseTerminalController {
    let testUndoManager = ExpiringUndoManager()
    override var undoManager: ExpiringUndoManager? { testUndoManager }
}

private final class LayoutTestController: TerminalController {
    let testUndoManager = ExpiringUndoManager()
    override var undoManager: ExpiringUndoManager? { testUndoManager }
}
