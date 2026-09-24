import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct ProjectWindowLayoutTests {
    private static var emojiFixtureApp: Ghostty.App?
    private static var tabMenuFixtureApp: Ghostty.App?
    @Test func draggingInactiveProjectHighlightsItWithoutSwitchingTerminals() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let first = makeWindow(app, width: 220)
        let second = makeWindow(app, width: 220)
        defer {
            for fixture in [first, second] {
                fixture.controller.window = nil
                fixture.window.close()
            }
        }
        first.window.addTabbedWindow(second.window, ordered: .above)
        second.window.makeKeyAndOrderFront(nil)
        let group = try #require(second.window.tabGroup)
        let model = group.tabSidebarModel
        for fixture in [first, second] { fixture.split.bind(to: model, animated: false) }
        await drainMainQueue()
        let table = try #require(descendants(of: second.split.sidebarSplitItem.viewController.view)
            .compactMap { $0 as? NSOutlineView }.first)
        let sourceIndex = try #require(model.projects.firstIndex { $0.id == first.controller.project.id })
        let sourceRow = try #require(table.rowView(atRow: sourceIndex, makeIfNecessary: true))
        let source = try #require(descendants(of: sourceRow)
            .compactMap { $0 as? ProjectSidebarRowInteraction.InteractionView }.first)
        let selected = model.selectedProjectID
        #expect(selected != first.controller.project.id)
        for commit in [false, true] {
            source.onDragBegan()
            await drainMainQueue()
            #expect(table.selectedRow == sourceIndex)
            #expect(model.selectedProjectID == selected)
            #expect(group.selectedWindow === second.window)
            if commit {
                #expect(model.acceptProjectDrop(.init(groupID: model.dragID, projectID: first.controller.project.id),
                                               at: model.projects.count))
                #expect(model.draggingProjectID == nil)
            }
            source.onDragEnded()
            await drainMainQueue()
            #expect(model.draggingProjectID == nil)
            #expect(table.selectedRow == model.projects.firstIndex { $0.id == selected })
            #expect(group.selectedWindow === second.window)
        }
    }

    @Test func sidebarRowsExposeNativeReorderDragAndInsertionGap() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        fixture.window.makeKeyAndOrderFront(nil)
        defer { fixture.controller.window = nil; fixture.window.close() }
        await drainMainQueue()
        let table = try #require(descendants(of: fixture.split.sidebarSplitItem.viewController.view)
            .compactMap { $0 as? NSTableView }.first)
        #expect(table.verticalMotionCanBeginDrag)
        #expect(table.draggingDestinationFeedbackStyle == .gap)
        // A model-only test cannot catch a missing native drop registration.
        #expect(table.registeredDraggedTypes.contains(.init(ProjectSidebarDragPayload.typeIdentifier)))
        #expect((table as? NSOutlineView)?.dataSource is ProjectSidebarDropCoordinator)
        let interaction = try #require(descendants(of: table)
            .compactMap { $0 as? ProjectSidebarRowInteraction.InteractionView }.first)
        #expect(interaction.bounds.width > 100)
        #expect(interaction.bounds.height >= 44)
        let content = try #require(fixture.window.contentView)
        let point = interaction.convert(NSPoint(x: interaction.bounds.midX, y: interaction.bounds.midY), to: content.superview)
        #expect(content.hitTest(point) === interaction)
    }

    @Test func projectEmojiPopoverCommitsClickAndCancelsOnDismiss() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.emojiFixtureApp = app
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        let terminal = Ghostty.SurfaceView(try #require(app.app))
        terminal.frame = NSRect(x: 300, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(terminal)
        fixture.controller.focusedSurface = terminal
        window.makeKeyAndOrderFront(nil)
        defer { fixture.controller.window = nil; window.close() }
        await drainMainQueue()
        let model = window.projectSidebarModel
        let emoji = "🧪"
        let projectID = fixture.controller.project.id
        // SwiftUI builds its accessibility tree only once an assistive client
        // asks for it; this is the attribute such clients set on the app.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(false, forAttribute: enhancedUI) }
        model.beginProjectEmojiEdit(projectID: projectID)
        let (popover, buttonFrame) = try await waitForPopoverButton(labeled: "Choose \(emoji)")
        #expect(popover !== window)
        click(buttonFrame, in: popover)
        await drainMainQueue()
        #expect(fixture.controller.project.emoji == emoji)
        #expect(model.editingProjectEmojiID == nil)
        #expect(window.firstResponder === terminal)
        try await waitUntil { !popover.isVisible }

        model.beginProjectEmojiEdit(projectID: projectID)
        let (reopened, _) = try await waitForPopoverButton(labeled: "Choose \(emoji)")
        // The unattended test host cannot activate, so the popover never
        // becomes key to receive the Escape keyDown; send the action Escape
        // is bound to from the popover's own responder chain instead.
        #expect(reopened.contentView?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)
        try await waitUntil { model.editingProjectEmojiID == nil }
        #expect(fixture.controller.project.emoji == emoji)
        #expect(window.firstResponder === terminal)
    }

    @Test func paneGrabHandleIsHittableThroughItsVisualPill() throws {
        let config = try TemporaryConfig("shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        // Release the native views and terminal before their owning core app.
        try autoreleasepool {
            let surface = Ghostty.SurfaceView(try #require(app.app))
            let host = NSHostingView(rootView:
                Ghostty.SurfaceGrabHandle(surfaceView: surface, isSplit: true, dragHandle: .auto))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 18),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            let source = try #require(descendants(of: host).first { $0 is NSDraggingSource })
            let frame = source.convert(source.bounds, to: host)
            #expect(frame.width >= 44)
            #expect(frame.height >= 18)
            #expect(host.hitTest(NSPoint(x: frame.midX, y: frame.midY)) === source)
        }
        withExtendedLifetime(app) {}
    }

    @Test func projectContextMenuCoversTheNativeRowInsets() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = NSTableRowView(frame: NSRect(x: 10, y: 50, width: 260, height: 48))
        let context = ProjectSidebarContextMenu.ContextView(makeMenu: { NSMenu() })
        context.frame = NSRect(x: 12, y: 8, width: 70, height: 32)
        row.addSubview(context)
        window.contentView?.addSubview(row)
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: 250, y: 24)] {
            #expect(context.containsMenuPoint(row.convert(point, to: nil)))
        }
        #expect(!context.containsMenuPoint(row.convert(NSPoint(x: 100, y: 60), to: nil)))
        #expect(context.hitTest(NSPoint(x: 20, y: 20)) == nil)
    }

    @Test func rapidSidebarTogglesSettleWithoutResizingHiddenTabsRepeatedly() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let first = makeWindow(app, width: 280)
        let second = makeWindow(app, width: 280)
        defer {
            for fixture in [first, second] {
                fixture.controller.window = nil
                fixture.window.close()
            }
        }
        first.window.addTabbedWindow(second.window, ordered: .above)
        second.window.makeKeyAndOrderFront(nil)
        let group = try #require(second.window.tabGroup)
        let model = group.tabSidebarModel
        for fixture in [first, second] {
            fixture.split.bind(to: model, animated: false)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
        }
        await drainMainQueue()
        model.setVisible(false)
        // The hidden window completes synchronously, without a queued
        // animation or the additional main-queue hop that caused the lag.
        #expect(first.split.sidebarSplitItem.isCollapsed)
        model.setVisible(true)
        model.setVisible(false)
        model.setVisible(true)
        try await Task.sleep(for: .milliseconds(300))
        for fixture in [first, second] {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            #expect(!fixture.split.sidebarSplitItem.isCollapsed)
            #expect(abs(fixture.split.sidebarColumnWidth - 280) < 1)
        }
        #expect(model.sidebarState.isVisible)
        #expect(model.sidebarState.expandedWidth == 280)
    }

    @Test func tabHoverPreviewNeverSelectsTheTabAndCancelsPendingPresentation() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        window.orderFront(nil)
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        let preview = ProjectTabHoverPreview()
        // Activation is covered by ProjectTabCraftTests; this test owns
        // presentation and placement, which a test host cannot key-gate.
        preview.isInteractionWindowActive = { _ in true }
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

    @Test func tabHoverPreviewCentersOnEachHoveredTabAfterLayout() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        window.orderFront(nil)
        let second = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let third = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let selectedWindow = try #require(third.window)
        selectedWindow.makeKeyAndOrderFront(nil)
        let preview = ProjectTabHoverPreview()
        // Activation is covered by ProjectTabCraftTests; this test owns
        // presentation and placement, which a test host cannot key-gate.
        preview.isInteractionWindowActive = { _ in true }
        defer {
            preview.dismiss()
            for controller in [third, second, fixture.controller] {
                let window = controller.window
                controller.window = nil
                window?.close()
            }
        }
        // Let the selected-tab width animation and toolbar layout settle.
        try await Task.sleep(for: .milliseconds(250))
        await drainMainQueue()
        let strip = try #require(selectedWindow.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        let cells = descendants(of: strip).compactMap { $0 as? ProjectTabCellHostingView }
        let inactive = cells.filter { !$0.rootView.isSelected }.sorted {
            $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX
        }
        #expect(inactive.count == 2)
        var centers: [CGFloat] = []
        for cell in inactive {
            let hostWindow = try #require(cell.window)
            let anchor = hostWindow.convertToScreen(cell.convert(cell.bounds, to: nil))
            #expect(!cell.canShowHoverPreview(at: NSPoint(x: cell.bounds.maxX + 8, y: cell.bounds.midY)))
            preview.hover(cell, at: NSPoint(x: cell.bounds.midX, y: cell.bounds.midY))
            preview.show()
            let panel = try #require(hostWindow.childWindows?.first { $0 is NSPanel })
            panel.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(panel.frame.midX - anchor.midX) < 1)
            #expect(abs(panel.frame.maxY - (anchor.minY - 8)) < 1)
            // AppKit aligns fractional tab centers to the backing pixels.
            #expect(abs(panel.frame.width - 280) <= 1)
            #expect(abs(panel.frame.height - 196) <= 1)
            centers.append(panel.frame.midX)
            #expect(selectedWindow.tabGroup?.selectedWindow === selectedWindow)
            preview.dismiss()
        }
        #expect(centers.count == 2 && abs(centers[0] - centers[1]) > 100)
    }

    @Test func tabDragCancellationReleasesTheSessionForTheNextGesture() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /bin/cat")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        window.orderFront(nil)
        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        let tabWindow = try #require(tab.window)
        defer {
            NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
            tab.window = nil
            tabWindow.close()
            fixture.controller.window = nil
            window.close()
        }
        let group = try #require(tabWindow.tabGroup)
        for notification in [NSApplication.willResignActiveNotification, NSWindow.willCloseNotification] {
            group.selectedWindow = tabWindow
            await drainMainQueue()
            let strip = try #require(tabWindow.toolbar?.items.first {
                $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
            }?.view)
            let cell = try #require(descendants(of: strip).compactMap { $0 as? ProjectTabCellHostingView }
                .first { $0.rootView.row.window === tabWindow })
            let point = NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: cell.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: tabWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            ProjectTabDragSession.begin(from: cell, event: event, grabPoint: point)
            #expect(group.tabSidebarModel.liftedTabID == ObjectIdentifier(tabWindow))
            NotificationCenter.default.post(name: notification, object: tabWindow)
            #expect(group.tabSidebarModel.liftedTabID == nil)
            #expect(group.windows == [window, tabWindow])
        }
    }

    @Test func movedToolbarResolvesItsTerminalAndUsesItsOwnScreenCoordinates() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let window = fixture.window
        window.orderFront(nil)
        await drainMainQueue()
        let toolbarWindow = NSWindow(contentRect: NSRect(x: 600, y: 600, width: 800, height: 60),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        toolbarWindow.isReleasedWhenClosed = false
        defer {
            toolbarWindow.contentView = nil
            toolbarWindow.close()
            fixture.controller.window = nil
            window.close()
        }
        let strip = try #require(window.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view)
        // Model AppKit reparenting the toolbar into its fullscreen host.
        strip.removeFromSuperview()
        toolbarWindow.contentView = strip
        #expect(ProjectTabDragSession.terminalWindow(hosting: toolbarWindow) === window)
        let frame = try #require(ProjectTabDragSession.screenFrame(of: strip))
        #expect(frame == toolbarWindow.convertToScreen(strip.convert(strip.bounds, to: nil)))
        #expect(frame != window.convertToScreen(strip.convert(strip.bounds, to: nil)))
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

        let hasRailMaterial = descendants(of: host)
            .compactMap { $0 as? NSVisualEffectView }
            .contains { $0.material == .titlebar }
        #expect(hasRailMaterial || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
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
        #expect(toolbarBackground.material == .titlebar)
        #expect(toolbarBackground.blendingMode == .behindWindow)
        let terminalFrame = split.contentViewForSizing.convert(split.contentViewForSizing.bounds, to: container)
        #expect(abs(toolbarBackground.frame.minX - terminalFrame.minX) < 1)
        #expect(abs(toolbarBackground.frame.maxX - container.bounds.maxX) < 1)
        #expect(abs(toolbarBackground.frame.maxY - container.bounds.maxY) < 1)
        #expect(abs(toolbarBackground.frame.height - TerminalController.projectToolbarInset(window)) < 1)
        #expect(toolbarBackground.hitTest(NSPoint(x: toolbarBackground.frame.midX,
                                                 y: toolbarBackground.frame.midY)) == nil)

        // Collapsing the sidebar must extend the toolbar material all the
        // way left; expanding restores the boundary between the two shades.
        for isVisible in [false, true] {
            split.applySidebarState(SidebarState(isVisible: isVisible, expandedWidth: 260), animated: false)
            container.layoutSubtreeIfNeeded()
            await drainMainQueue()
            let contentLeft = split.contentViewForSizing.convert(split.contentViewForSizing.bounds, to: container).minX
            #expect(abs(toolbarBackground.frame.minX - contentLeft) < 1)
            #expect(isVisible ? contentLeft >= 260 : abs(contentLeft) < 1)
            #expect(abs(toolbarBackground.frame.maxX - container.bounds.maxX) < 1)
        }
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

    /// The local monitor consumes only bare list clicks. A synthetic
    /// `NSApp.sendEvent` call bypasses local monitors, so test the event filter
    /// against the rendered table's actual geometry.
    @Test func sidebarEmptyAreaClickFilterPreservesRowsAndContextMenu() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let fixture = makeWindow(app, width: 220)
        let controller = fixture.controller
        let window = fixture.window
        let split = fixture.split
        defer { controller.window = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()

        let sidebarView = split.sidebarSplitItem.viewController.view
        let table = try #require(descendants(of: sidebarView)
            .compactMap { $0 as? NSTableView }
            .first { $0.numberOfRows > 0 })
        let clickGuard = try #require(descendants(of: sidebarView)
            .compactMap { $0 as? ProjectSidebarEmptyClickGuard.GuardView }.first)
        let monitorHandler = clickGuard.makeEventMonitorHandler()

        // Find a point on the table's surface with no row under it.
        var emptyPoint: NSPoint?
        var y = table.bounds.maxY - 2
        while y > 0 {
            let candidate = NSPoint(x: table.bounds.midX, y: y)
            if table.row(at: candidate) == -1 {
                emptyPoint = candidate
                break
            }
            y -= 4
        }
        let pointInWindow = table.convert(try #require(emptyPoint), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: pointInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(monitorHandler(down) == nil)

        let controlDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: pointInWindow, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        #expect(monitorHandler(controlDown) === controlDown)

        let firstRow = table.rect(ofRow: 0)
        let rowPoint = table.convert(NSPoint(x: firstRow.midX, y: firstRow.midY), to: nil)
        let rowDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: rowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        #expect(monitorHandler(rowDown) === rowDown)
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

    /// Verifies that the tab menu embeds a compact, accessible color palette.
    @Test func tabContextMenuUsesCompactAccessiblePalette() throws {
        let window = TerminalWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.tabColor = .purple
        let menu = makeProjectTabContextMenu(for: window)
        let row = try #require(menu.items.compactMap { $0.view as? TabColorPaletteRowView }.first)
        let buttons = row.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == TerminalTabColor.allCases.count)
        #expect(row.frame.width <= 320)
        #expect(row.frame.height >= 30)
        #expect(buttons.map(\.tag) == TerminalTabColor.allCases.map(\.rawValue))
        #expect(buttons.allSatisfy { $0.image?.size == NSSize(width: 22, height: 22) })
        buttons[TerminalTabColor.green.rawValue].performClick(nil)
        #expect(window.tabColor == .green)
        buttons[TerminalTabColor.none.rawValue].performClick(nil)
        #expect(window.tabColor == .none)
    }

    /// Verifies that the tab menu offers valid moves and keeps close actions last.
    @Test func tabContextMenuShowsOnlyAvailableProjectMovesAndClosesLast() throws {
        let config = try TemporaryConfig(
            "macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.tabMenuFixtureApp = app
        let core = try #require(app.app)
        let project = TerminalProject(name: "Shared")
        let controllers = (0..<4).map { index in
            let controller = ProjectTabMenuTestController(
                app, withSurfaceTree: .init(view: Ghostty.SurfaceView(core)), usesProjectSidebar: true)
            controller.project = index < 3 ? project : TerminalProject(name: "Other")
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach {
                $0.focusedSurface = nil
                $0.window?.contentView = nil
                $0.window = nil
            }
            windows.forEach { $0.close() }
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        windows[2].addTabbedWindow(windows[3], ordered: .above)
        #expect(windows[0].tabGroup?.windows.count == 4)
        let ordered = controllers[0].projectTabWindows
        #expect(ordered.count == 3)

        /// Returns the actionable text-item titles in a window's tab menu.
        func titles(for window: NSWindow) -> [String] {
            makeProjectTabContextMenu(for: window).items.compactMap { item in
                item.isSeparatorItem || item.view != nil ? nil : item.title
            }
        }

        let first = titles(for: ordered[0])
        #expect(!first.contains("Move Tab Left"))
        #expect(first.contains("Move Tab Right"))
        #expect(first.contains("Close Tabs to the Right"))

        let middle = titles(for: ordered[1])
        #expect(middle.contains("Move Tab Left"))
        #expect(middle.contains("Move Tab Right"))

        let lastMenu = makeProjectTabContextMenu(for: ordered[2])
        let last = titles(for: ordered[2])
        #expect(last.contains("Move Tab Left"))
        #expect(!last.contains("Move Tab Right"))
        #expect(!last.contains("Close Tabs to the Right"))
        #expect(lastMenu.items.suffix(2).map(\.title) == ["Close Tab", "Close Other Tabs"])
        let moveItemsEnabled = lastMenu.items.filter { $0.title.hasPrefix("Move Tab") }
            .allSatisfy { $0.isEnabled }
        #expect(moveItemsEnabled)

        let moving = try #require(ordered[1].windowController as? ProjectTabMenuTestController)
        ProjectTabMovement(window: ordered[1]).move(by: -1)
        #expect(moving.projectTabWindows == [ordered[1], ordered[0], ordered[2]])
        #expect(moving.testUndoManager.undoActionName == "Move Tab")
        moving.testUndoManager.undo()
        #expect(moving.projectTabWindows == ordered)
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

    /// The popover is hosted in its own window, so search every window's
    /// accessibility tree rather than the sidebar's view hierarchy.
    private func waitForPopoverButton(labeled label: String) async throws -> (NSWindow, NSRect) {
        for _ in 0..<100 {
            // Start from content views: a popover is also an accessibility
            // child of its parent window, which must not receive the events.
            for window in NSApp.windows where window.isVisible {
                guard let content = window.contentView,
                      let frame = accessibilityButtonFrame(in: content, labeled: label) else { continue }
                return (window, frame)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No visible window contains a button labeled \(label)")
        throw CancellationError()
    }

    // SwiftUI's accessibility nodes answer the NSAccessibility selectors
    // without declaring protocol conformance, so dispatch dynamically.
    private func accessibilityButtonFrame(in element: AnyObject, labeled label: String) -> NSRect? {
        if let role = element.accessibilityRole?(), role == .button,
           let elementLabel = element.accessibilityLabel?(), elementLabel == label {
            return element.accessibilityFrame?()
        }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = accessibilityButtonFrame(in: child as AnyObject, labeled: label) { return frame }
        }
        return nil
    }

    private func click(_ screenFrame: NSRect, in window: NSWindow) {
        let location = window.convertPoint(fromScreen: NSPoint(x: screenFrame.midX, y: screenFrame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            if let event { window.sendEvent(event) }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

private final class ProjectTabMenuTestController: TerminalController {
    let testUndoManager = ExpiringUndoManager()
    /// Exposes the test-owned undo manager to tab movement operations.
    override var undoManager: ExpiringUndoManager? { testUndoManager }
}
