import AppKit
import SwiftUI

/// Uses the same compact native swatch row as the tab menu.
func makeProjectContextMenu(project: TerminalProject, model: TabSidebarModel) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ProjectTabMenuItem("Rename Project…") { model.beginRename(projectID: project.id) })
    menu.addItem(ProjectTabMenuItem("Change Emoji…") { model.beginProjectEmojiEdit(projectID: project.id) })
    let reset = ProjectTabMenuItem("Reset Project Appearance") { model.resetProjectAppearance(for: project.id) }
    reset.isEnabled = project.emoji != nil || project.color != .none
    menu.addItem(reset)
    menu.addItem(.separator())
    // The restore target is empty until a tab records selection, so fall
    // back to the project's first row like `projectController` does.
    let targetController = {
        (model.restoreTargetRow(for: project.id)
            ?? model.rows.first(where: { $0.project.id == project.id }))
            .flatMap { $0.window.windowController as? TerminalController }
    }
    menu.addItem(ProjectTabMenuItem("Close Project") { targetController()?.closeProject() })
    menu.addItem(ProjectTabMenuItem("New Project") { targetController()?.newProject(nil) })
    menu.addItem(.separator())
    if #available(macOS 14.0, *) {
        menu.addItem(.sectionHeader(title: "Project Color"))
    }
    let palette = makeProjectTabColorMenu(selected: project.color) { model.setProjectColor($0, for: project.id) }
    for item in palette.items {
        item.view?.setAccessibilityLabel("Project Color")
        palette.removeItem(item)
        menu.addItem(item)
    }
    return menu
}

struct ProjectSidebarContextMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> ContextView { ContextView(makeMenu: makeMenu) }
    func updateNSView(_ view: ContextView, context: Context) { view.makeMenu = makeMenu }

    final class ContextView: NSView {
        var makeMenu: () -> NSMenu
        private var monitor: Any?

        init(makeMenu: @escaping () -> NSMenu) {
            self.makeMenu = makeMenu
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        // Preserve the list's selection, double-click and text-field gestures.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
