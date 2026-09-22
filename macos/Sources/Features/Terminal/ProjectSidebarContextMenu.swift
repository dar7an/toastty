import AppKit
import SwiftUI

/// Uses the same compact native swatch row as the tab menu.
func makeProjectContextMenu(project: TerminalProject, model: TabSidebarModel) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ProjectTabMenuItem("Rename Project…") { model.beginRename(projectID: project.id) })
    // The restore target is empty until a tab records selection, so fall
    // back to the project's first row like `projectController` does.
    let targetController = {
        (model.restoreTargetRow(for: project.id)
            ?? model.rows.first(where: { $0.project.id == project.id }))
            .flatMap { $0.window.windowController as? TerminalController }
    }
    menu.addItem(ProjectTabMenuItem("New Project") { targetController()?.newProject(nil) })
    menu.addItem(.separator())

    menu.addItem(ProjectTabMenuItem("Change Emoji…") {
        // Let native menu tracking restore its responder before presenting
        // the text-input anchor for the character picker.
        DispatchQueue.main.async { model.beginProjectEmojiEdit(projectID: project.id) }
    })
    if project.emoji != nil {
        menu.addItem(ProjectTabMenuItem("Reset Emoji") { model.resetProjectEmoji(for: project.id) })
    }

    if #available(macOS 14.0, *) {
        menu.addItem(.sectionHeader(title: "Project Color"))
    }
    let palette = makeProjectTabColorMenu(selected: project.color) { model.setProjectColor($0, for: project.id) }
    for item in palette.items {
        item.view?.setAccessibilityLabel("Project Color")
        palette.removeItem(item)
        menu.addItem(item)
    }
    if project.emoji != nil || project.color != .none {
        menu.addItem(ProjectTabMenuItem("Reset Project Appearance") {
            model.resetProjectAppearance(for: project.id)
        })
    }

    let moveItems: [ProjectTabMenuItem] = [("Move Project Up", -1), ("Move Project Down", 1)].compactMap { item in
        let (title, offset) = item
        guard model.canMoveProject(project.id, by: offset) else { return nil }
        return ProjectTabMenuItem(title) { model.moveProject(project.id, by: offset) }
    }
    if !moveItems.isEmpty {
        menu.addItem(.separator())
        moveItems.forEach(menu.addItem)
    }

    menu.addItem(.separator())
    let delete = ProjectTabMenuItem("Delete Project") { targetController()?.closeProject() }
    delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    menu.addItem(delete)
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

        /// Include the native row's selection background and insets, not just
        /// the hosted label. Otherwise right-clicking its trailing space opens
        /// the list's empty-area menu instead of the project's menu.
        func containsMenuPoint(_ point: NSPoint) -> Bool {
            let row = sequence(first: self as NSView, next: { $0.superview })
                .compactMap { $0 as? NSTableRowView }.first
            let region = row ?? self
            return region.bounds.contains(region.convert(point, from: nil))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      self.containsMenuPoint(event.locationInWindow) else { return event }
                NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
