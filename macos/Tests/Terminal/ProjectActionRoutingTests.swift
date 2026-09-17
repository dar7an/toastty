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
