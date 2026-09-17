//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @MainActor
    @Test func defaultSizeTracksSidebarWidth() {
        let view = TerminalViewContainer { Color.clear.frame(width: 10, height: 10) }
        view.initialContentSize = NSSize(width: 800, height: 480)
        var sidebarWidth: CGFloat = 220
        view.initialContentWidthInset = { sidebarWidth }
        view.initialContentHeightInset = { sidebarWidth > 0 ? 90 : 0 }
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        for width: CGFloat in [220, 160, 320, 0] {
            sidebarWidth = width
            TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
            #expect(view.frame.width == 800 + width)
            #expect(abs(view.frame.height - CGFloat(480 + (width > 0 ? 90 : 0))) < 0.5)
        }
    }

    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }

    @MainActor
    @Test func sidebarInsetCountsOnlyWhenExpanded() {
        let view = TerminalViewContainer { Color.clear.frame(width: 10, height: 10) }
        view.initialContentSize = NSSize(width: 800, height: 480)
        var expanded = true
        var expandedWidth: CGFloat = 220
        // Mirrors TerminalController.tabSidebarInset: the expanded width only
        // when visible, and no height inset — the native toolbar overlays the
        // content, so its geometry is counted exactly once.
        view.initialContentWidthInset = { expanded ? expandedWidth : 0 }
        view.initialContentHeightInset = { 0 }
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        #expect(view.frame.width == 1020)
        #expect(abs(view.frame.height - 480) < 0.5)

        expandedWidth = 300
        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        #expect(view.frame.width == 1100)
        #expect(abs(view.frame.height - 480) < 0.5)

        // Collapsed: the terminal keeps its full configured size.
        expanded = false
        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        #expect(view.frame.width == 800)
        #expect(abs(view.frame.height - 480) < 0.5)
    }

    @MainActor
    @Test func projectSplitEmbedKeepsContainerAsContentView() throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = TerminalController(app, withSurfaceTree: .init(), usesProjectSidebar: true)
        let split = ProjectSplitViewController(controller: controller, content: AnyView(EmptyView()))
        let container = TerminalViewContainer { EmptyView() }
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        container.embedProjectSplitViewController(split)
        window.contentView = container

        // Controller lookups and background glass keep working: the content
        // view is still the container, with the split view filling it.
        #expect(window.contentView as? TerminalViewContainer === container)
        #expect(container.projectSplitViewController === split)
        #expect(split.splitViewItems.count == 2)
        #expect(!split.sidebarSplitItem.isCollapsed)
    }
}
