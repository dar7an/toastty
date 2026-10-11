//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import ObjectiveC
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

private class BackgroundPolicyTestWindow: TerminalWindow {
    var transparencyAllowed = true
    override var allowsBackgroundTransparency: Bool { transparencyAllowed }
    override var isVisible: Bool { true }
}

private class AccessibilityAppearanceTestController: TerminalController {
    var appearanceUpdates = 0
    override func syncAppearance() { appearanceUpdates += 1 }
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

@MainActor
@Suite(.serialized)
struct TerminalViewContainerTests {
    @Test func runtimeClassDiscoverySupportsOlderMacOS() throws {
        // XCTest and other Objective-C clients enumerate classes without
        // constructing views. Availability annotations alone must not leave
        // a stored Glass value that requires macOS 26 metadata at this point.
        var count: UInt32 = 0
        let classes = try #require(objc_copyClassList(&count))
        defer { free(UnsafeMutableRawPointer(classes)) }
        #expect(count > 0)
        // Do not bridge every returned class to AnyObject for an identity
        // comparison: private runtime classes need not support that messaging.
        // Copying the list already forces the metadata realization we test.
    }

    @Test func displayAccessibilityChangesRefreshExistingControllers() async throws {
        let config = try TemporaryConfig("shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = AccessibilityAppearanceTestController(app, withSurfaceTree: .init())
        let before = controller.appearanceUpdates
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        await drainMainQueue()
        #expect(controller.appearanceUpdates == before + 1)
    }

    @Test func accessibilityObserverDoesNotRetainController() async throws {
        let config = try TemporaryConfig("shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        weak var releasedController: AccessibilityAppearanceTestController?
        // Drain autoreleased ownership separately from the delivery test's
        // assertion temporaries, including a notification queued at release.
        autoreleasepool {
            let controller = AccessibilityAppearanceTestController(app, withSurfaceTree: .init())
            releasedController = controller
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        // AppKit can also defer cleanup to the run loop. A real observer
        // retain cycle still fails this bounded wait.
        for _ in 0..<100 {
            let released = autoreleasepool { releasedController == nil }
            if released { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(releasedController == nil)
    }

    @Test(arguments: [false, true])
    func glassTracksOpacityAndStaysBehindContent(projectMode: Bool) async throws {
        guard #available(macOS 26.0, *) else { return }
        let config = try TemporaryConfig("background-blur = macos-glass-regular\nbackground-opacity = 0.5\n" +
            "shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = TerminalController(app, withSurfaceTree: .init(), usesProjectSidebar: projectMode)
        let container = MockTerminalViewContainer { Color.clear.frame(width: 300, height: 200) }
        if projectMode {
            container.embedProjectSplitViewController(ProjectSplitViewController(
                controller: controller, content: AnyView(Color.clear.frame(width: 300, height: 200))))
        }
        let window = BackgroundPolicyTestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let surfaceConfig = Ghostty.SurfaceView.DerivedConfig(config)

        window.syncAppearance(surfaceConfig)
        container.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        let glass = try #require(container.glassEffectView)
        container.layoutSubtreeIfNeeded()
        #expect(!window.isOpaque)
        #expect(container.subviews.first === glass)
        #expect(glass.hitTest(NSPoint(x: 20, y: 20)) == nil)
        #expect(glass.isAccessibilityHidden())

        // Exercise the same unchanged config across an accessibility,
        // fullscreen, or explicit opaque-policy transition.
        window.transparencyAllowed = false
        window.syncAppearance(surfaceConfig)
        container.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        await drainMainQueue()
        #expect(window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 1)
        #expect(container.glassEffectView == nil)
        #expect(glass.superview == nil)

        window.transparencyAllowed = true
        window.syncAppearance(surfaceConfig)
        container.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        #expect(!window.isOpaque)
        #expect(container.glassEffectView != nil)
        #expect(container.subviews.first === container.glassEffectView)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

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
            let target = NSSize(width: 800 + width, height: 480 + (width > 0 ? 90 : 0))
            #expect(view.intrinsicContentSize == target)
            expectContentSize(target, in: window)
        }
    }

    @Test func glassAvailability() async throws {
        let view = MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }

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
        expectContentSize(NSSize(width: 1020, height: 480), in: window)

        expandedWidth = 300
        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        expectContentSize(NSSize(width: 1100, height: 480), in: window)

        // Collapsed: the terminal keeps its full configured size.
        expanded = false
        TerminalController.DefaultSize.contentIntrinsicSize.apply(to: window)
        expectContentSize(NSSize(width: 800, height: 480), in: window)
    }

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

    @Test func laidOutTerminalIncludesToolbarInDefaultSize() throws {
        let config = try TemporaryConfig("shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controller = TerminalController(app, withSurfaceTree: .init(), usesProjectSidebar: true)
        let split = ProjectSplitViewController(
            controller: controller, content: AnyView(Color.clear.frame(width: 800, height: 480)))
        let container = TerminalViewContainer { EmptyView() }
        container.embedProjectSplitViewController(split)
        container.initialContentWidthInset = { 220 }
        container.initialContentHeightInset = { 52 }

        // Once the terminal supplies its ideal size, the toolbar must still be
        // counted. Otherwise Return to Default Size removes terminal rows.
        #expect(container.intrinsicContentSize == NSSize(width: 1020, height: 532))
    }

    private func expectContentSize(_ target: NSSize, in window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main, let view = window.contentView else {
            Issue.record("A window and screen are required for native sizing tests")
            return
        }
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        #expect(abs(view.frame.width - min(target.width, available.width)) < 0.5)
        #expect(abs(view.frame.height - min(target.height, available.height)) < 0.5)
    }
}
