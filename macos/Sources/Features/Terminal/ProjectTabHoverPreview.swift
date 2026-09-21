import AppKit
import SwiftUI

/// A single, delayed preview for the tab rail. It never selects a tab or
/// reparents a terminal, and disappears before an input event is delivered.
@MainActor
final class ProjectTabHoverPreview: NSObject {
    static let shared = ProjectTabHoverPreview()
    private let delay: TimeInterval
    private weak var source: ProjectTabCellHostingView?
    private weak var tabWindow: NSWindow?
    private var timer: Timer?
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true }
    var isPending: Bool { timer != nil }

    init(delay: TimeInterval = 0.5) {
        self.delay = delay
        super.init()
    }

    func hover(_ cell: ProjectTabCellHostingView, at point: NSPoint) {
        guard cell.canShowHoverPreview(at: point) else {
            leave(cell)
            return
        }
        guard source !== cell || tabWindow !== cell.rootView.row.window else { return }
        let nextDelay = isVisible ? min(delay, 0.1) : delay
        dismiss()
        source = cell
        tabWindow = cell.rootView.row.window
        observeDismissal(in: cell.window)
        let timer = Timer(timeInterval: nextDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func leave(_ cell: ProjectTabCellHostingView) {
        if source === cell { dismiss() }
    }

    func validate(_ cell: ProjectTabCellHostingView) {
        guard source === cell else { return }
        if tabWindow !== cell.rootView.row.window || !cell.canShowHoverPreview {
            dismiss()
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        source = nil
        tabWindow = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        panel = nil
    }

    private func observeDismissal(in window: NSWindow?) {
        let notifications: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window), (NSWindow.willCloseNotification, window),
            (NSWindow.didMoveNotification, window), (NSWindow.didResizeNotification, window),
            (NSWindow.willMiniaturizeNotification, window),
            (NSApplication.willResignActiveNotification, nil), (NSMenu.didBeginTrackingNotification, nil)
        ]
        observers = notifications.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .keyDown, .scrollWheel
        ]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved, let source = self.source, event.window === source.window {
                let point = source.convert(event.locationInWindow, from: nil)
                if !source.canShowHoverPreview(at: point) { self.dismiss() }
            } else {
                self.dismiss()
            }
            return event
        }
    }

    func show() {
        // A cancelled timer must not reopen the preview after a click or exit.
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        guard let source, let window = source.window,
              tabWindow === source.rootView.row.window, source.canShowHoverPreview else {
            dismiss()
            return
        }
        let row = source.rootView.row
        let snapshot = ProjectTabSnapshot.image(of: row.window)
        let size = NSSize(width: ProjectTabHoverCard.width, height: ProjectTabHoverCard.height)
        let anchor = window.convertToScreen(source.convert(source.hoverPreviewRect, to: nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        let frame = Self.frame(size: size, below: anchor, on: screen)
        guard frame.width > 0, frame.height > 0 else {
            dismiss()
            return
        }
        let content = ProjectTabHoverCard(
            title: row.title, directory: row.pwd, snapshot: snapshot,
            shortcutHint: source.rootView.shortcutHint, size: frame.size)
        let panel = ProjectTabPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = source.effectiveAppearance
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        self.panel = panel
        // Only the appearance fades. Dismissal is synchronous so previews
        // never linger over typing, menus, drags, or a newly selected tab.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    static func frame(size: NSSize, below anchor: NSRect, on screen: NSRect) -> NSRect {
        ProjectTabPreviewLayout.frame(size: size, below: anchor, on: screen)
    }
}

private final class ProjectTabPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Capture only the terminal content, including its splits. The same native
/// view snapshot is used for hover and tear-off previews, with no disk cache.
@MainActor
enum ProjectTabSnapshot {
    static func image(of window: NSWindow) -> NSImage? {
        let content = (window.contentView as? TerminalViewContainer)?
            .projectSplitViewController?.contentSplitItem.viewController.view ?? window.contentView
        guard let content, content.bounds.width > 0, content.bounds.height > 0,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

struct ProjectTabHoverCard: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    static let width: CGFloat = 280
    static let height: CGFloat = 196
    let title: String
    let directory: String?
    let snapshot: NSImage?
    var shortcutHint: String?
    var size = CGSize(width: ProjectTabHoverCard.width, height: ProjectTabHoverCard.height)

    private var subtitle: String? {
        guard let directory, !directory.isEmpty, directory != title else { return nil }
        return directory
    }

    private var footerHeight: CGFloat { min(subtitle == nil ? 40 : 58, size.height) }
    private var thumbnailHeight: CGFloat { max(0, size.height - footerHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let snapshot {
                    // Keep terminal output against the top-left edge when a
                    // tall or wide window needs cropping to the thumbnail.
                    Image(nsImage: snapshot).resizable().scaledToFill()
                } else {
                    Color(nsColor: .textBackgroundColor)
                        .overlay {
                            Image(systemName: "terminal")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: size.width, height: thumbnailHeight, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .bottom) {
                ProjectChrome.separatorColor
                    .frame(height: ProjectChrome.hairline(displayScale: displayScale))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let shortcutHint, !shortcutHint.isEmpty {
                        Text(shortcutHint)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: size.width, height: footerHeight, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: ProjectChrome.previewCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ProjectChrome.previewCornerRadius, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor),
                              lineWidth: contrast == .increased ? 1 : ProjectChrome.hairline(displayScale: displayScale))
        }
        // The tab already exposes its title, path, shortcut, and actions.
        // A pointer-only preview must not add a duplicate VoiceOver target.
        .accessibilityHidden(true)
    }
}
