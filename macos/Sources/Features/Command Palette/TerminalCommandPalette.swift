import SwiftUI
import GhosttyKit

func sortedTerminalPaletteOptions(_ options: [CommandOption]) -> [CommandOption] {
    options.sorted { lhs, rhs in
        let lhsTitle = lhs.title.replacingOccurrences(of: ":", with: "\t")
        let rhsTitle = rhs.title.replacingOccurrences(of: ":", with: "\t")
        let comparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        if let lhsKey = lhs.sortKey, let rhsKey = rhs.sortKey {
            return lhsKey < rhsKey
        }
        return false
    }
}

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    restoreTerminalFocusAfterPalette(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updateOptions)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: sortedTerminalPaletteOptions(
            jumpOptions + projectOptions + appearanceOptions + terminalOptions))
        return options
    }

    /// Keep appearance discoverable from the keyboard as well as the View menu.
    private var appearanceOptions: [CommandOption] {
        guard let controller = BaseTerminalController.controller(owning: surfaceView) else { return [] }
        return ToasttyAppearance.allCases.map { appearance in
            CommandOption(title: "Appearance: \(appearance.title)", leadingIcon: "circle.lefthalf.filled") {
                ToasttyAppearance.saved = appearance
                controller.ghostty.reloadConfig()
            }
        }
    }

    /// Commands for installing or canceling available updates.
    /// Debug-only simulator controls; nightlies use Sparkle’s standard dialogs.
    private var updateOptions: [CommandOption] {
        #if DEBUG
        var options: [CommandOption] = []

        guard let updateViewModel else {
            return options
        }

        if updateViewModel.state.isInstallable {
            // We override the update available one only because we want to properly
            // convey it'll go all the way through.
            let title: String
            if case .updateAvailable = updateViewModel.state {
                title = "Update Toastty and Restart"
            } else {
                title = updateViewModel.text
            }

            options.append(CommandOption(
                title: title,
                description: updateViewModel.description,
                leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
                badge: updateViewModel.badge,
                emphasis: true
            ) {
                (NSApp.delegate as? AppDelegate)?.updateController.viewModel.state.confirm()
            })
        }

        if updateViewModel.state.isCancellable {
            options.append(CommandOption(
                title: "Cancel or Skip Update",
                description: "Dismiss the current update process"
            ) {
                updateViewModel.state.cancel()
            })
        }

        return options
        #else
        return []
        #endif
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        return ghosttyConfig.commandPaletteEntries
            .filter(\.isSupported)
            .filter { entry in
                switch entry.action.split(separator: ":").first {
                case "new_project", "toggle_project_sidebar", "goto_project", "next_project", "previous_project":
                    return projectController != nil
                default:
                    return true
                }
            }
            .map { c in
                let symbols = ghosttyConfig.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil
            let projectName = projectDisplayName(controller.project)

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                // Include the project name so identical tab titles across
                // projects stay distinguishable. Pwd is appended when it adds
                // information beyond the title.
                var subtitleParts: [String] = [projectName]
                if let pwd, !displayTitle.contains(pwd), !projectName.contains(pwd) {
                    subtitleParts.append(pwd)
                }
                let subtitle: String = subtitleParts.joined(separator: " — ")

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: ObjectIdentifier(surface)
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

    /// Only the owning workspace can supply project actions. Quick Terminal
    /// must never fall back to an unrelated background window.
    private var projectController: TerminalController? {
        guard let controller = BaseTerminalController.controller(owning: surfaceView) as? TerminalController,
              controller.usesProjectSidebar else { return nil }
        return controller
    }

    /// Contextual project commands complement the configured core commands.
    private var projectOptions: [CommandOption] {
        guard let active = projectController else { return [] }
        var options: [CommandOption] = []

        options.append(CommandOption(
            title: "Rename Project…",
            description: "Rename the current project (\(projectDisplayName(active.project)))",
            leadingIcon: "pencil"
        ) { [weak active] in active?.promptProjectName(rename: true) })

        options.append(CommandOption(
            title: "Close Project",
            description: "Close all tabs in \(projectDisplayName(active.project))",
            leadingIcon: "folder.badge.minus"
        ) { [weak active] in active?.closeProject() })

        // Switch to each project, with the current project first for
        // stable ordering alongside the sorted jump options.
        if let group = active.window?.tabGroup {
            let model = group.tabSidebarModel
            for project in model.projects {
                let name = projectDisplayName(project)
                let isCurrent = project.id == active.project.id
                let directory = model.directory(for: project)
                options.append(CommandOption(
                    title: isCurrent ? "Switch Project: \(name) (Current)" : "Switch Project: \(name)",
                    subtitle: directory,
                    leadingIcon: isCurrent ? "folder.fill" : "folder"
                ) { [weak active] in
                    guard let window = active?.window, let tabGroup = window.tabGroup else { return }
                    tabGroup.tabSidebarModel.selectProject(project.id, stealFocus: false)
                })
            }
        }

        return options
    }

}

/// Dismissal must not override focus assigned by the command itself (a rename
/// field, a sheet, a search field, or a different tab/window).
@MainActor
func restoreTerminalFocusAfterPalette(_ surface: Ghostty.SurfaceView) {
    guard let window = surface.window,
          window.isKeyWindow,
          window.attachedSheet == nil,
          surface.searchState == nil else { return }
    if let controller = window.windowController as? TerminalController,
       controller.usesProjectSidebar,
       window.tabGroup?.tabSidebarModel.editingProjectID != nil {
        return
    }
    // If focus already lives in a text editor (project rename field, tab
    // rename, search field, or the test's standalone field), don't yank it
    // back to the terminal. This covers rename sessions whose model hasn't
    // rebuilt rows yet, where `editingProjectID` alone can't prove editing.
    if let firstResponder = window.firstResponder, firstResponder !== surface {
        if firstResponder is NSTextView || firstResponder is NSTextField {
            return
        }
    }
    window.makeFirstResponder(surface)
}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
