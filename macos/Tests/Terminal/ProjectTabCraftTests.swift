import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct ProjectTabCraftTests {
    @Test func nonfiniteRailWidthsFallBackToUsableCells() {
        for available: CGFloat in [.nan, .infinity, -.infinity] {
            let widths = ProjectTabStripView.cellWidths(available: available, count: 3, selectedIndex: 1)
            #expect(widths == [54, 120, 54])
            #expect(widths.allSatisfy(\.isFinite))
        }
    }

    @Test func hairlinesRejectNonfiniteDisplayScales() {
        for scale: CGFloat in [.nan, .infinity, -.infinity, 0, -1] {
            #expect(ProjectChrome.hairline(displayScale: scale) == 1)
        }
        #expect(ProjectChrome.hairline(displayScale: 2) == 0.5)
    }

    @Test func clickThroughCanSelectButCannotCloseATab() throws {
        let fixture = Fixture { _ in }
        defer { fixture.close() }
        let close = try fixture.event(.leftMouseDown, at: CGPoint(x: 10, y: 14))
        let select = try fixture.event(.leftMouseDown, at: CGPoint(x: 80, y: 14))
        #expect(!fixture.host.acceptsFirstMouse(for: close))
        #expect(fixture.host.acceptsFirstMouse(for: select))
        #expect(!fixture.host.acceptsFirstMouse(for: nil))
    }

    @Test func pointerFeedbackTracksPressExitReentryAndRelease() throws {
        var selections = 0
        let fixture = Fixture { _ in selections += 1 }
        defer { fixture.close() }
        let down = try fixture.event(.leftMouseDown, at: CGPoint(x: 80, y: 14))
        fixture.host.mouseDown(with: down)
        #expect(fixture.host.rootView.isPressed)
        #expect(selections == 0)
        fixture.host.mouseExited(with: down)
        #expect(!fixture.host.rootView.isPressed)
        fixture.host.mouseEntered(with: down)
        #expect(fixture.host.rootView.isPressed)
        fixture.host.mouseUp(with: try fixture.event(.leftMouseUp, at: CGPoint(x: 80, y: 14)))
        #expect(!fixture.host.rootView.isPressed)
        #expect(selections == 1)
    }

    @Test func releasingOutsideDoesNotSelectOrLeavePressedChrome() throws {
        var selections = 0
        let fixture = Fixture { _ in selections += 1 }
        defer { fixture.close() }
        fixture.host.mouseDown(with: try fixture.event(.leftMouseDown, at: CGPoint(x: 80, y: 14)))
        fixture.host.mouseUp(with: try fixture.event(.leftMouseUp, at: CGPoint(x: 300, y: 14)))
        #expect(!fixture.host.rootView.isPressed)
        #expect(!fixture.host.rootView.isHovered)
        #expect(selections == 0)
    }

    @Test func closePressDoesNotMasqueradeAsTabSelection() throws {
        var selections = 0
        let fixture = Fixture { _ in selections += 1 }
        defer { fixture.close() }
        fixture.host.mouseDown(with: try fixture.event(.leftMouseDown, at: CGPoint(x: 10, y: 14)))
        #expect(!fixture.host.rootView.isPressed)
        // Moving out of the close target cancels; it must not select instead.
        fixture.host.mouseUp(with: try fixture.event(.leftMouseUp, at: CGPoint(x: 80, y: 14)))
        #expect(selections == 0)
    }

    @Test func anInactiveWindowDoesNotScheduleHoverPreviews() {
        let fixture = Fixture { _ in }
        defer { fixture.close() }
        fixture.window.orderFront(nil)
        fixture.host.layoutSubtreeIfNeeded()
        #expect(fixture.window.isVisible)
        #expect(!fixture.window.isKeyWindow)
        #expect(!fixture.host.canShowHoverPreview)
        let preview = ProjectTabHoverPreview()
        defer { preview.dismiss() }
        preview.hover(fixture.host, at: CGPoint(x: 80, y: 14))
        #expect(!preview.isPending)
        #expect(!preview.isVisible)
    }

    @Test func auxiliaryToolbarResolvesTheSelectedTerminalAsInteractionWindow() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let selected = NSWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false)
        let tab = NSWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false)
        let toolbar = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        for window in [selected, tab, toolbar] { window.isReleasedWhenClosed = false }
        defer {
            toolbar.contentView = nil
            for window in [toolbar, tab, selected] { window.close() }
        }
        selected.addTabbedWindow(tab, ordered: .above)
        let group = try #require(selected.tabGroup)
        group.selectedWindow = selected
        let row = TabSidebarModel.Row(window: tab, project: TerminalProject(), title: "Build")
        let host = ProjectTabCellHostingView(rootView: ProjectTabCell(
            row: row, isSelected: false, onSelect: { _ in }, showSeparator: false, width: 190))
        toolbar.contentView = host
        #expect(host.window === toolbar)
        #expect(host.previewInteractionWindow === selected)
    }

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let host: ProjectTabCellHostingView

        init(onSelect: @escaping (TabSidebarModel.Row.ID) -> Void) {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 190, height: 28),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let row = TabSidebarModel.Row(window: window, project: TerminalProject(), title: "Build")
            let host = ProjectTabCellHostingView(rootView: ProjectTabCell(
                row: row, isSelected: false, onSelect: onSelect, showSeparator: false, width: 190))
            self.window = window
            self.host = host
            window.contentView = host
            host.frame = CGRect(x: 0, y: 0, width: 190, height: 28)
            host.layoutSubtreeIfNeeded()
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
