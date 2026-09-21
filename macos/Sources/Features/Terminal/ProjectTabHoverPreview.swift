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
        let content = ProjectTabHoverCard(title: row.title, directory: row.pwd,
                                         shortcut: source.rootView.shortcutHint, snapshot: snapshot)
        let size = NSSize(width: ProjectTabHoverCard.width, height: content.height)
        let anchor = window.convertToScreen(source.convert(source.visibleRect, to: nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        let frame = Self.frame(size: size, below: anchor, on: screen)
        let panel = ProjectTabPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = source.effectiveAppearance
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    static func frame(size: NSSize, below anchor: NSRect, on screen: NSRect) -> NSRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(anchor.midX - width / 2, screen.minX), screen.maxX - width)
        let y = min(max(anchor.minY - height - 8, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
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

private struct ProjectTabHoverCard: View {
    static let width: CGFloat = 300
    let title: String
    let directory: String?
    let shortcut: String?
    let snapshot: NSImage?

    private var thumbnailHeight: CGFloat {
        guard let snapshot, snapshot.size.width > 0 else { return 160 }
        return min(200, max(112, Self.width * snapshot.size.height / snapshot.size.width))
    }
    var height: CGFloat { 62 + thumbnailHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(directory ?? "Terminal")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().scaledToFit()
                } else {
                    Image(systemName: "terminal").font(.system(size: 32)).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.width, height: thumbnailHeight)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(title)")
    }
}
