import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct ProjectWindowLayoutTests {
    @Test func tabHoverPreviewNeverSelectsTheTabAndCancelsPendingPresentation() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        window.orderFront(nil)
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        let preview = ProjectTabHoverPreview()
        defer {
            preview.dismiss()
            tab.window = nil
            tabWindow.close()
            fixture.controller.window = nil
            window.close()
        }
        await drainMainQueue()
        let group = try #require(tabWindow.tabGroup)
        let strip = try #require(tabWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        let cells = descendants(of: strip).compactMap { $0 as? ProjectTabCellHostingView }
        let inactive = try #require(cells.first { $0.rootView.row.window === window })
        let selected = try #require(cells.first { $0.rootView.row.window === tabWindow })
        let point = NSPoint(x: inactive.bounds.midX, y: inactive.bounds.midY)
        preview.hover(inactive, at: point)
        #expect(preview.isPending)
        #expect(!preview.isVisible)
        preview.leave(inactive)
        preview.show()
        #expect(!preview.isPending)
        #expect(!preview.isVisible)

        preview.hover(inactive, at: point)
        preview.show()
        #expect(preview.isVisible)
        #expect(group.selectedWindow === tabWindow)
        let panel = try #require(tabWindow.childWindows?.first { $0 is NSPanel })
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isKeyWindow)
        // Preview dismissal must precede the normal click/drag path.
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: tabWindow)
        #expect(!preview.isVisible)
        preview.hover(selected, at: NSPoint(x: selected.bounds.midX, y: selected.bounds.midY))
        #expect(!preview.isPending)
        preview.hover(inactive, at: NSPoint(x: 10, y: inactive.bounds.midY))
        #expect(!preview.isPending) // Close-button hover keeps its own tooltip.
        #expect(group.windows == [window, tabWindow])
    }

    @Test func nativeToolbarFillsAvailableWidthAndPreservesTerminalHeight() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 260)
        let controller = fixture.controller
        let window = fixture.window
        let container = fixture.container
        let split = fixture.split
        defer { controller.window = nil; window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        #expect(abs(split.sidebarColumnWidth - 260) < 1)
        let item = try #require(window.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        })
        let host = try #require(item.view)
        let contentView = try #require(window.contentView)
        let sidebarColumn = try #require(split.splitView.arrangedSubviews.first)
        let hostFrame = host.convert(host.bounds, to: contentView)
        let sidebarFrame = sidebarColumn.convert(sidebarColumn.bounds, to: contentView)
        #expect(hostFrame.minX >= sidebarFrame.maxX)
        #expect(hostFrame.maxX <= contentView.bounds.maxX)
        #expect(hostFrame.width > 0)
        #expect(window.titlebarSeparatorStyle == .line)

        #expect(descendants(of: host)
            .compactMap { $0 as? NSVisualEffectView }
            .contains { $0.material == .titlebar })
        #expect(descendants(of: host).contains { $0 is ProjectTabCellHostingView })
        let newTab = try #require(window.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.newTabItemIdentifier
        })
        let sidebar = try #require(window.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.sidebarToggleItemIdentifier
        })
        #expect(newTab.isBordered)
        #expect(newTab.action == #selector(TerminalController.newTab(_:)))
        #expect(newTab.target === controller)
        #expect(newTab.view == nil)
        #expect(sidebar.isBordered)
        #expect(sidebar.view == nil)
        #expect(sidebar.action == #selector(ProjectSplitViewController.toggleSidebar(_:)))
        #expect(sidebar.target === split)
        #expect(split.sidebarSplitItem.titlebarSeparatorStyle == .none)
        #expect(split.sidebarSplitItem.allowsFullHeightLayout)

        let sidebarView = split.sidebarSplitItem.viewController.view
        let tables = descendants(of: sidebarView).compactMap { $0 as? NSTableView }
        #expect(tables.contains { $0.numberOfRows == 1 })
        let material = try #require(descendants(of: sidebarView)
            .compactMap { $0 as? NSVisualEffectView }.first { $0.material == .sidebar })
        let materialFrame = material.convert(material.bounds, to: sidebarView)
        // The background must cover its hosting view. AppKit owns the inset
        // between that view and the window (8pt on macOS 26), so comparing
        // their edges tests private system layout rather than our background.
        #expect(sidebarView.bounds.width > 0)
        #expect(sidebarView.bounds.height > 0)
        #expect(materialFrame.maxY >= sidebarView.bounds.maxY - 1)
        #expect(materialFrame.minY <= sidebarView.bounds.minY + 1)
        #expect(materialFrame.maxX >= sidebarView.bounds.maxX - 1)
        #expect(materialFrame.minX <= sidebarView.bounds.minX + 1)

        container.initialContentSize = NSSize(width: 800, height: 480)
        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        #expect(TerminalController.projectToolbarInset(window) > 0)
        #expect(abs(window.contentLayoutRect.height - 480) < 1)

        // The navigation material follows native toolbar geometry without
        // covering terminal content or intercepting window-drag events.
        let toolbarBackground = try #require(container.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(toolbarBackground.material == .sidebar)
        #expect(toolbarBackground.blendingMode == .behindWindow)
        #expect(abs(toolbarBackground.frame.width - container.bounds.width) < 1)
        #expect(abs(toolbarBackground.frame.maxY - container.bounds.maxY) < 1)
        #expect(abs(toolbarBackground.frame.height - TerminalController.projectToolbarInset(window)) < 1)
        #expect(toolbarBackground.hitTest(NSPoint(x: toolbarBackground.frame.midX,
                                                 y: toolbarBackground.frame.midY)) == nil)
    }

    @Test func nativeDividerResizeUpdatesSharedState() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let controller = fixture.controller
        let window = fixture.window
        let split = fixture.split
        defer { controller.window = nil; window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        split.splitView.setPosition(280, ofDividerAt: 0)
        await drainMainQueue()
        #expect(abs(split.sidebarColumnWidth - 280) < 1)
        #expect(window.tabGroup?.tabSidebarModel.width == split.sidebarColumnWidth)
        #expect(controller.sidebarState?.expandedWidth == split.sidebarColumnWidth)

        // Reapplying a measured width must not subtract AppKit's content inset
        // on every layout pass, including after a collapse and expansion.
        for _ in 0..<3 {
            split.applySidebarState(SidebarState(isVisible: false, expandedWidth: 280), animated: false)
            split.applySidebarState(SidebarState(isVisible: true, expandedWidth: 280), animated: false)
            window.contentView?.layoutSubtreeIfNeeded()
            await drainMainQueue()
            #expect(abs(split.sidebarColumnWidth - 280) < 1)
            #expect(abs((controller.sidebarState?.expandedWidth ?? 0) - 280) < 1)
        }
    }

    @Test func renderedTabCellIncludesItsPadding() {
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = TabSidebarModel.Row(window: window, project: TerminalProject(directory: "/tmp"), title: "Terminal")
        let cell = NSHostingView(rootView: ProjectTabCell(
            row: row, isSelected: true, onSelect: { _ in }, showSeparator: false, width: 198))
        #expect(abs(cell.fittingSize.width - 198) < 0.5)
    }

    @Test func tabMouseClicksReachSelectionWithoutStartingADrag() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = TabSidebarModel.Row(window: window, project: TerminalProject(directory: "/tmp"), title: "Terminal")
        var selected: [ObjectIdentifier] = []
        let host = ProjectTabCellHostingView(rootView: ProjectTabCell(
            row: row, isSelected: false, onSelect: { selected.append($0) }, showSeparator: false, width: 280))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        window.contentView = host
        let point = host.convert(NSPoint(x: 140, y: 13), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        host.mouseDown(with: down)
        #expect(selected.isEmpty)
        host.mouseUp(with: up)
        #expect(selected == [row.id])
        // A cancelled drag/release cannot invoke selection a second time.
        host.mouseUp(with: up)
        #expect(selected.count == 1)
    }

    @Test(arguments: [true, false])
    func tabTearOffUsesNativeStandaloneWindow(selected: Bool) async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let controller = fixture.controller
        let window = fixture.window
        fixture.split.beginObservingTabGroup()
        window.orderFront(nil)
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        defer {
            tab.window = nil
            tabWindow.close()
            controller.window = nil
            window.close()
        }
        tabWindow.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let originalGroup = try #require(tabWindow.tabGroup)
        let strip = try #require(tabWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        let cell = try #require(descendants(of: strip)
            .compactMap { $0 as? ProjectTabCellHostingView }
            .first { $0.rootView.row.window === tabWindow })

        if !selected { originalGroup.selectedWindow = window }
        let originalSelection = originalGroup.selectedWindow
        let drag = ProjectTabDragSession(source: cell, grabPoint: NSPoint(x: cell.bounds.width / 4, y: 14))
        let model = originalGroup.tabSidebarModel
        drag.lift()
        await drainMainQueue()
        #expect(originalGroup.windows == [window, tabWindow])
        #expect(originalGroup.selectedWindow === window)
        #expect(model.railTabs.map(\.window) == [window])
        #expect(model.visibleTabs.count == 2)
        let pointer = NSPoint(x: 500, y: 600)
        for progress: CGFloat in [0, 0.5, 1] {
            let frame = drag.previewFrame(at: pointer, progress: progress)
            #expect(abs(frame.minX + frame.width / 4 - pointer.x) < 0.5)
            #expect(abs(frame.maxY - pointer.y - 14) < 0.5)
        }
        drag.end(cancelled: true, at: pointer)
        await drainMainQueue()
        #expect(originalGroup.selectedWindow === originalSelection)
        #expect(model.liftedTabID == nil)
        #expect(model.railTabs.map(\.window) == [window, tabWindow])

        let tearOff = ProjectTabDragSession(source: cell, grabPoint: NSPoint(x: cell.bounds.midX, y: 14))
        tearOff.lift()
        let screen = try #require(NSScreen.main)
        let edge = NSPoint(x: screen.visibleFrame.maxX - 5, y: screen.visibleFrame.minY + 5)
        tearOff.finish(accepted: false, detach: true, at: edge)
        await drainMainQueue()
        #expect(originalGroup.windows == [window])
        #expect(tabWindow.tabGroup == nil)
        #expect(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(tabWindow.frame))
        #expect(tab.project.id == controller.project.id)
        let detachedModel = tabWindow.standaloneTabSidebarModel
        #expect(detachedModel.rows.map(\.window) == [tabWindow])
        let detachedSplit = try #require((tabWindow.contentView as? TerminalViewContainer)?
            .projectSplitViewController)
        #expect(detachedSplit.model === detachedModel)

        // Detached windows have no native tab group, but must retain the
        // same sidebar actions, saved geometry, and inline project rename.
        detachedSplit.splitView.setPosition(280, ofDividerAt: 0)
        await drainMainQueue()
        #expect(abs(detachedModel.width - 280) < 1)
        #expect(abs((tab.sidebarState?.expandedWidth ?? 0) - 280) < 1)
        tab.toggleProjectSidebar(nil)
        #expect(!detachedModel.sidebarState.isVisible)
        let toggle = NSMenuItem(title: "", action: #selector(TerminalController.toggleProjectSidebar(_:)),
                                keyEquivalent: "")
        #expect(tab.validateMenuItem(toggle))
        #expect(toggle.title == "Show Sidebar")
        tab.toggleProjectSidebar(nil)
        #expect(detachedModel.sidebarState.isVisible)
        #expect(tab.validateMenuItem(toggle))
        #expect(toggle.title == "Hide Sidebar")
        tab.promptProjectName(rename: true)
        #expect(detachedModel.editingProjectID == tab.project.id)
        detachedModel.editingDraft = "Detached Project"
        detachedModel.commitRename()
        #expect(detachedModel.projects.first?.name == "Detached Project")
    }

    @Test func nativeReorderCrossesMidpointsAndMovesOnlyInterveningTabs() {
        #expect(ProjectTabCellHostingView.tearOffDistance == 28)
        let widths: [CGFloat] = [100, 160, 80, 120]
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 39, widths: widths) == 1)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 41, widths: widths) == 2)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: -49, widths: widths) == 1)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: -51, widths: widths) == 0)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 900, widths: widths) == 3)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: .infinity, widths: widths) == 1)
        #expect(ProjectTabReorderGesture.neighborOffset(index: 2, source: 1, destination: 3, width: 160) == -160)
        #expect(ProjectTabReorderGesture.neighborOffset(index: 0, source: 1, destination: 3, width: 100) == 0)
        #expect(ProjectTabReorderGesture.neighborOffset(index: 1, source: 3, destination: 0, width: 100) == 100)
    }

    @Test func widerSelectedTabCanReorderWithinItsClampedTravel() {
        let widths: [CGFloat] = [54, 190, 54, 54]
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 26, widths: widths) == 1)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 28, widths: widths) == 2)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 80, widths: widths) == 2)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 82, widths: widths) == 3)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: -54, widths: widths) == 0)
        #expect(ProjectTabReorderGesture.destination(source: 1, translation: 108, widths: widths) == 3)
        #expect(ProjectTabReorderGesture.destination(source: 0, translation: 54, widths: [54, 54]) == 1)
    }

    @Test func tabContextMenuUsesCompactAccessiblePalette() throws {
        let window = TerminalWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.tabColor = .purple
        let menu = makeProjectTabContextMenu(for: window)
        let row = try #require(menu.items.last?.view as? TabColorPaletteRowView)
        let buttons = row.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == TerminalTabColor.allCases.count)
        #expect(row.frame.width <= 260)
        #expect(row.frame.height >= 30)
        #expect(buttons.map(\.tag) == TerminalTabColor.allCases.map(\.rawValue))
        #expect(buttons.allSatisfy { $0.image?.size == NSSize(width: 18, height: 18) })
        buttons[TerminalTabColor.green.rawValue].performClick(nil)
        #expect(window.tabColor == .green)
        buttons[TerminalTabColor.none.rawValue].performClick(nil)
        #expect(window.tabColor == .none)
    }

    @Test func tabRailAlwaysReordersAcrossTheCell() {
        #expect(ProjectTabDropState.calculate(atX: 0, width: 200) == .before)
        #expect(ProjectTabDropState.calculate(atX: 99, width: 200) == .before)
        #expect(ProjectTabDropState.calculate(atX: 100, width: 200) == .after)
        #expect(ProjectTabDropState.calculate(atX: 199, width: 200) == .after)
        #expect(ProjectTabDropState.calculate(atX: 0, width: 0) == .idle)
    }

    @Test func commandPaletteTakesFocusFromTerminalContent() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: CommandPaletteSearchField(query: .constant("")))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let field = try #require(descendants(of: host).compactMap {
            $0 as? CommandPaletteSearchField.SearchField
        }.first)
        #expect(field.currentEditor() === window.firstResponder)
        #expect(window.firstResponder is NSTextView)
    }

    /// Exercise native layout without starting a terminal process or relying on
    /// SwiftUI terminal focus callbacks, which are covered by desktop checks.
    private struct WindowFixture {
        let controller: TerminalController
        let window: TerminalWindow
        let container: TerminalViewContainer
        let split: ProjectSplitViewController
    }

    private func makeWindow(
        _ app: Ghostty.App,
        width: CGFloat
    ) -> WindowFixture {
        let controller = TerminalController(app, withSurfaceTree: .init(), usesProjectSidebar: true)
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                    styleMask: [.titled, .resizable, .closable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        let model = window.tabGroup!.tabSidebarModel
        model.setExpandedWidth(width)
        let split = ProjectSplitViewController(controller: controller, content: AnyView(Color.clear))
        split.bind(to: model, animated: false)
        let container = TerminalViewContainer { EmptyView() }
        container.embedProjectSplitViewController(split)
        container.initialContentWidthInset = { model.width }
        container.initialContentHeightInset = { [weak window] in
            window.map(TerminalController.projectToolbarInset) ?? 0
        }
        window.contentView = container
        window.configureProjectChrome(splitController: split)
        return WindowFixture(controller: controller, window: window, container: container, split: split)
    }

    private func drainMainQueue() async {
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
