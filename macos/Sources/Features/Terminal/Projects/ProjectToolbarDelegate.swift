import AppKit
import SwiftUI

/// Builds the single native toolbar row for one project window:
/// `[traffic lights sidebar toggle] | [project tabs …][+]`.
///
/// - The toggle uses the standard `.toggleSidebar` slot; its action travels
///   the responder chain to `ProjectSplitViewController.toggleSidebar`.
/// - The separator is an `NSTrackingSeparatorToolbarItem` bound to divider 0,
///   so it follows the sidebar divider with constraints, never
///   screen-coordinate offsets.
/// - The tab strip is the shared ``ProjectTabStripView`` in a flexible,
///   borderless item (`isBordered = false`); overflow scrolls inside the
///   strip while the toggle and strip keep high visibility priority at
///   minimum window widths.
/// - New Tab is a separate native, bordered toolbar item so its sizing and
///   glass bezel follow the same AppKit metrics as Toggle Sidebar.
///
/// Toolbar identity is window-specific: each window gets its own delegate
/// instance (retained by its split controller) with autosave disabled, so
/// configuration never propagates to unrelated windows.
final class ProjectToolbarDelegate: NSObject, NSToolbarDelegate {
    static let tabStripItemIdentifier = NSToolbarItem.Identifier("com.ghostty.projectTabStrip")
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
        [.toggleSidebar, .sidebarTrackingSeparator, Self.tabStripItemIdentifier, Self.newTabItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.tabStripItemIdentifier, Self.newTabItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
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
            item.toolTip = "New Tab (⌘T)"
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
            item.toolTip = "Project tabs"
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

    private func tabStripView() -> some View {
        Group {
            if let model = tabStripModel {
                ProjectTabStripView(
                    model: model,
                    onSelect: { [weak model] in model?.select($0) })
            } else {
                EmptyView()
            }
        }
    }
}
