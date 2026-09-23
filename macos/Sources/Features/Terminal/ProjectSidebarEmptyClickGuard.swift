import AppKit
import SwiftUI

/// Consumes left-clicks that land on the project list's empty surface.
///
/// The sidebar `List` is backed by an `NSTableView`, which takes first
/// responder for any click inside its frame — even below the last row, where
/// the click only deselects. `TabSidebarModel.selectProject(nil)` keeps the
/// current project, so the click's sole effect is moving focus off the
/// terminal and repainting the selected row with the key-window accent
/// highlight. Consume that click and restore terminal focus after dispatch.
struct ProjectSidebarEmptyClickGuard: NSViewRepresentable {
    var model: TabSidebarModel

    func makeNSView(context: Context) -> GuardView { GuardView(model: model) }
    func updateNSView(_ view: GuardView, context: Context) { view.model = model }

    final class GuardView: NSView {
        var model: TabSidebarModel
        private var monitor: Any?

        init(model: TabSidebarModel) {
            self.model = model
            super.init(frame: .zero)
            autoresizingMask = [.width, .height]
        }

        required init?(coder: NSCoder) { nil }

        // Never intercept hit tests; the monitor works off window geometry.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.filteredEvent(event) ?? event
            }
        }

        /// Local monitors receive physical clicks before AppKit dispatches
        /// them to the table. A direct `NSApp.sendEvent` test bypasses them.
        func filteredEvent(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, !isHiddenOrHasHiddenAncestor,
                  // Keep ctrl+click's "New Project" context menu and
                  // clicks outside the list's frame on their native paths.
                  !event.modifierFlags.contains(.control),
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  isEmptyListSurface(at: event.locationInWindow)
            else { return event }

            // Preserve the side effects the click used to carry: app and
            // window activation, and dismissal of the inline editors.
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if let window, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if model.editingProjectID != nil { model.commitRename() }
            if model.editingProjectEmojiID != nil { model.cancelProjectEmojiEdit() }
            // AppKit can give the list first responder after this mouse-down
            // monitor returns. Restore typing focus once dispatch finishes.
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isKeyWindow,
                      let controller = window.windowController as? TerminalController,
                      let surface = controller.focusedSurface else { return }
                window.makeFirstResponder(surface)
            }
            return nil
        }

        /// True when the hit-tested view at a window point is the list's bare
        /// surface — the table between/below rows or the clip view under a
        /// short table — with no row at the point. Row cells, editors,
        /// scrollers, and titlebar views resolve to their own views.
        private func isEmptyListSurface(at point: NSPoint) -> Bool {
            guard let hit = window?.contentView?.hitTest(point) else { return false }
            let table = (hit as? NSTableView)
                ?? (hit as? NSClipView)?.documentView as? NSTableView
                ?? (hit as? NSScrollView)?.documentView as? NSTableView
            guard let table else { return false }
            return table.row(at: table.convert(point, from: nil)) == -1
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
