import AppKit
import Combine

/// Track one uninterrupted internal tab gesture, with a non-interactive
/// window preview above the app. The tab stays in its original group until
/// release, so Escape restores it without reconstructing terminal surfaces.
/// A normal NSWindow drag cannot offer split targets; a pasteboard drag hides
/// its cancellation event inside AppKit's tracking loop. Owning this gesture
/// keeps cancellation, rail re-entry, and split drops on the same path.
@MainActor
final class ProjectTabDragSession: NSObject {
    private static var active: ProjectTabDragSession?
    static let feedback = ProjectTabDragFeedback()

    private let source: ProjectTabCellHostingView
    private let sourceWindow: NSWindow
    private let model: TabSidebarModel
    private let originalSelection: NSWindow?
    private let preview: ProjectTabDragPreview
    private let grabFraction: CGFloat
    private let grabTopOffset: CGFloat
    private var eventMonitor: Any?
    private var previewWindow: NSPanel?
    private var previewImageView: NSImageView?
    private var pointer = NSPoint.zero
    private var animationTimer: Timer?
    private var morph = ProjectTabDragMorph()
    private var lastFrameTime: CFTimeInterval = 0
    private var cancelled = false

    init(source: ProjectTabCellHostingView, grabPoint: NSPoint) {
        self.source = source
        sourceWindow = source.rootView.row.window
        model = sourceWindow.projectSidebarModel
        originalSelection = sourceWindow.tabGroup?.selectedWindow ?? sourceWindow
        grabFraction = min(1, max(0, grabPoint.x / max(1, source.bounds.width)))
        grabTopOffset = source.isFlipped ? grabPoint.y : source.bounds.height - grabPoint.y
        preview = ProjectTabDragPreview(source: source)
        super.init()
    }

    static func begin(from source: ProjectTabCellHostingView, event: NSEvent, grabPoint: NSPoint) {
        guard active == nil,
              source.rootView.row.window.windowController is TerminalController else { return }
        ProjectTabHoverPreview.shared.dismiss()
        let drag = ProjectTabDragSession(source: source, grabPoint: grabPoint)
        NSApp.activate(ignoringOtherApps: true)
        drag.originalSelection?.makeKeyAndOrderFront(nil)
        active = drag // The source host may disappear when its neighbor is selected.
        drag.pointer = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        drag.showPreview()
        drag.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .rightMouseDown]
        ) { [weak drag] event in
            guard let drag else { return event }
            switch event.type {
            case .leftMouseDragged:
                drag.move(to: event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
            case .leftMouseUp:
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                // A quick flick can release in the same event-loop turn as
                // native tab selection. Let AppKit finish ordering the newly
                // selected window before resolving the screen-space target.
                DispatchQueue.main.async { [weak drag] in
                    drag?.end(cancelled: false, at: point)
                }
            case .keyDown where event.keyCode == 53, .rightMouseDown:
                drag.end(cancelled: true, at: drag.pointer)
            default:
                return event
            }
            return nil
        }
        drag.lift()
        drag.startAnimation()
        NSCursor.closedHand.set()
    }

    private func showPreview() {
        let frame = previewFrame(at: pointer, progress: 0)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = preview.image(progress: 0)
        panel.contentView = imageView
        previewImageView = imageView
        previewWindow = panel
        panel.orderFrontRegardless()
    }

    /// Exposes the neighboring terminal as a split target without moving or
    /// duplicating the dragged tab's live surfaces.
    func lift() {
        guard !cancelled else { return }
        model.liftedTabID = ObjectIdentifier(sourceWindow)
        if originalSelection === sourceWindow,
           let controller = sourceWindow.windowController as? TerminalController {
            let windows = controller.projectTabWindows
            if let index = windows.firstIndex(of: sourceWindow), windows.count > 1 {
                let next = windows[index == windows.count - 1 ? index - 1 : index + 1]
                sourceWindow.tabGroup?.selectedWindow = next
            }
        }
        (sourceWindow.tabGroup?.selectedWindow ?? sourceWindow).makeKeyAndOrderFront(nil)
        model.refresh()
        updateTarget(at: pointer)
    }

    private func move(to point: NSPoint) {
        pointer = point
        updateTarget(at: point)
        let window = sourceWindow.tabGroup?.selectedWindow ?? sourceWindow
        let strip = window.toolbar?.items.first {
            $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
        }?.view
        let overRail = strip.map {
            window.convertToScreen($0.convert($0.bounds, to: nil)).insetBy(dx: 0, dy: -8).contains(point)
        } ?? false
        let target: CGFloat = overRail ? 0 : 1
        if morph.target != target {
            morph.target = target
            startAnimation()
        }
        updatePreview()
        NSCursor.closedHand.set()
    }

    func end(cancelled: Bool, at point: NSPoint) {
        guard !self.cancelled else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        previewWindow?.close()
        previewWindow = nil
        previewImageView = nil
        let accepted = !cancelled && commitDrop(at: point)
        let hitWindowNumber = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        let isOverWindow = NSApp.window(withWindowNumber: hitWindowNumber) != nil
        finish(accepted: accepted, detach: !cancelled && !accepted && !isOverWindow, at: point)
        NSCursor.arrow.set()
        if Self.active === self { Self.active = nil }
    }

    func finish(accepted: Bool, detach: Bool, at point: NSPoint) {
        cancelled = true
        Self.feedback.target = nil
        Self.feedback.railTarget = nil
        model.liftedTabID = nil
        guard let controller = sourceWindow.windowController as? TerminalController,
              !controller.isWindowClosed, !controller.surfaceTree.isEmpty else {
            model.refresh()
            return
        }
        if detach {
            source.detachForWindowDrag()
            var frame = sourceWindow.frame
            let screen = NSScreen.screens.first { $0.frame.contains(point) }
            if let visibleFrame = screen?.visibleFrame {
                frame.size.width = min(frame.width, visibleFrame.width)
                frame.size.height = min(frame.height, visibleFrame.height)
            }
            frame.origin = NSPoint(x: point.x - frame.width * grabFraction,
                                   y: point.y + grabTopOffset - frame.height)
            if let visibleFrame = screen?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
            }
            sourceWindow.setFrame(sourceWindow.constrainFrameRect(frame, to: screen), display: true)
            sourceWindow.makeKeyAndOrderFront(nil)
        } else if let originalSelection,
                  !accepted || originalSelection === sourceWindow,
                  sourceWindow.tabGroup?.windows.contains(originalSelection) == true {
            sourceWindow.tabGroup?.selectedWindow = originalSelection
            originalSelection.makeKeyAndOrderFront(nil)
        }
        model.refresh()
    }

    private func updateTarget(at point: NSPoint) {
        let target = splitTarget(at: point).map { ProjectTabDragFeedback.Target(surfaceID: $0.surface.id, zone: $0.zone) }
        if Self.feedback.target != target { Self.feedback.target = target }
        let railTarget = railTarget(at: point).map {
            ProjectTabDragFeedback.RailTarget(windowID: ObjectIdentifier($0.cell.rootView.row.window),
                                             position: $0.after ? .after : .before)
        }
        if Self.feedback.railTarget != railTarget { Self.feedback.railTarget = railTarget }
    }

    /// Resolve geometry against the frontmost visible terminal window, never
    /// an obscured terminal behind another Toastty window or a sheet.
    private func destinationWindow(at point: NSPoint) -> NSWindow? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number),
              window.attachedSheet == nil,
              window.windowController is TerminalController else { return nil }
        return window.tabGroup?.selectedWindow ?? window
    }

    private func splitTarget(
        at point: NSPoint, in destinationWindow: NSWindow? = nil
    ) -> (surface: Ghostty.SurfaceView, zone: TerminalSplitDropZone)? {
        guard let window = destinationWindow ?? self.destinationWindow(at: point),
              let sourceController = sourceWindow.windowController as? TerminalController,
              let destination = window.windowController as? TerminalController else { return nil }
        let payload = TerminalLayoutDragPayload.tab(sourceController.projectTabID)
        for surface in destination.surfaceTree {
            guard surface.window === window, !surface.isHiddenOrHasHiddenAncestor else { continue }
            var local = surface.convert(window.convertPoint(fromScreen: point), from: nil)
            guard surface.bounds.contains(local) else { continue }
            if !surface.isFlipped { local.y = surface.bounds.height - local.y }
            let previous = Self.feedback.target.flatMap { $0.surfaceID == surface.id ? $0.zone : nil }
            let zone = TerminalSplitDropZone.calculate(at: local, in: surface.bounds.size, preferring: previous)
            guard TerminalLayoutCoordinator.shared.proposal(for: payload, on: surface, zone: zone)?.isValid == true
            else { return nil }
            return (surface, zone)
        }
        return nil
    }

    @discardableResult
    func commitDrop(at point: NSPoint, in destinationWindow: NSWindow? = nil) -> Bool {
        guard let controller = sourceWindow.windowController as? TerminalController else { return false }
        if let target = splitTarget(at: point, in: destinationWindow) {
            TerminalLayoutCoordinator.shared.move(payload: .tab(controller.projectTabID),
                                                  into: target.surface, zone: target.zone)
            return true
        }
        guard let target = railTarget(at: point, in: destinationWindow),
              let sourceIndex = controller.projectTabWindows.firstIndex(of: sourceWindow),
              let targetIndex = controller.projectTabWindows.firstIndex(of: target.cell.rootView.row.window)
        else { return false }
        let insertion = targetIndex + (target.after ? 1 : 0)
        TerminalLayoutCoordinator.shared.reorderTab(controller.projectTabID,
            toProjectIndex: insertion - (sourceIndex < insertion ? 1 : 0))
        return true
    }

    private func railTarget(
        at point: NSPoint, in destinationWindow: NSWindow? = nil
    ) -> (cell: ProjectTabCellHostingView, after: Bool)? {
        guard let controller = sourceWindow.windowController as? TerminalController,
              let window = destinationWindow ?? self.destinationWindow(at: point),
              let strip = window.toolbar?.items.first(where: {
                  $0.itemIdentifier == ProjectToolbarDelegate.tabStripItemIdentifier
              })?.view else { return nil }
        func cells(in view: NSView) -> [ProjectTabCellHostingView] {
            view.subviews.flatMap { ($0 as? ProjectTabCellHostingView).map { [$0] } ?? cells(in: $0) }
        }
        for cell in cells(in: strip) {
            let frame = window.convertToScreen(cell.convert(cell.bounds, to: nil))
            guard frame.contains(point),
                  TerminalLayoutCoordinator.shared.canDropInTabBar(.tab(controller.projectTabID),
                                                                    beside: cell.rootView.row.window)
            else { continue }
            return (cell, point.x >= frame.midX)
        }
        return nil
    }

    func previewFrame(at point: NSPoint, progress: CGFloat) -> NSRect {
        let size = preview.size(progress: progress)
        return NSRect(x: point.x - size.width * grabFraction,
                      y: point.y + grabTopOffset - size.height, width: size.width, height: size.height)
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        lastFrameTime = CACurrentMediaTime()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            updatePreview()
            return
        }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.updatePreview()
                if self.morph.isSettled { timer.invalidate() }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func updatePreview() {
        guard let previewWindow, let previewImageView else { return }
        let now = CACurrentMediaTime()
        morph.advance(by: now - lastFrameTime, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastFrameTime = now
        let progress = min(1, max(0, morph.value))
        let frame = previewFrame(at: pointer, progress: progress)
        let image = preview.image(progress: progress)
        previewImageView.image = image
        previewWindow.setFrame(frame, display: true)
        previewWindow.invalidateShadow()
    }
}

@MainActor
final class ProjectTabDragFeedback: ObservableObject {
    struct Target: Equatable {
        let surfaceID: UUID
        let zone: TerminalSplitDropZone
    }
    @Published var target: Target?
    struct RailTarget: Equatable {
        let windowID: ObjectIdentifier
        let position: ProjectTabDropState
    }
    @Published var railTarget: RailTarget?
}

/// A critically damped spring preserves both position and velocity when a
/// drag reverses into the rail. Pointer translation itself is never animated.
struct ProjectTabDragMorph {
    var target: CGFloat = 1
    private(set) var value: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    var isSettled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

    mutating func advance(by interval: TimeInterval, reduceMotion: Bool) {
        guard !reduceMotion else { value = target; velocity = 0; return }
        let time = CGFloat(max(0, interval))
        let frequency: CGFloat = 30
        let displacement = value - target
        let coefficient = velocity + frequency * displacement
        let decay = exp(-frequency * time)
        value = target + (displacement + coefficient * time) * decay
        velocity = (velocity - frequency * coefficient * time) * decay
        if isSettled { value = target; velocity = 0 }
    }
}

/// Render once from the real tab/window, then resize a bounded preview. No
/// terminal views are reparented during a drag, so shells and splits stay live.
@MainActor
private final class ProjectTabDragPreview {
    private let tabImage: NSImage?
    private let windowImage: NSImage?
    private let tabSize: NSSize
    private let windowSize: NSSize
    private let appearance: NSAppearance
    private let title: String
    private var finalImage: NSImage?

    init(source: ProjectTabCellHostingView) {
        tabSize = source.bounds.size
        tabImage = Self.snapshot(source)
        let window = source.rootView.row.window
        windowImage = ProjectTabSnapshot.image(of: window)
        title = source.rootView.row.title
        let scale = min(1, min(420 / max(1, window.frame.width), 320 / max(1, window.frame.height)))
        windowSize = NSSize(width: window.frame.width * scale, height: window.frame.height * scale)
        appearance = source.effectiveAppearance
    }

    func size(progress: CGFloat) -> NSSize {
        NSSize(width: tabSize.width + (windowSize.width - tabSize.width) * progress,
               height: tabSize.height + (windowSize.height - tabSize.height) * progress)
    }

    func image(progress: CGFloat) -> NSImage {
        if progress >= 1, let finalImage { return finalImage }
        let size = size(progress: progress)
        let image = NSImage(size: size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size)
            let radius = 14 + (8 - 14) * progress
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            shape.addClip()
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            // A dragged tab represents one window, not a screenshot of the
            // old multi-tab toolbar. Keep its title and terminal recognizable.
            let headerHeight = min(tabSize.height, size.height)
            windowImage?.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height - headerHeight),
                              from: .zero, operation: .sourceOver, fraction: progress)
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            titleStyle.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: NSRect(x: 42, y: size.height - 21, width: max(0, size.width - 84), height: 16),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                     .foregroundColor: NSColor.labelColor.withAlphaComponent(progress),
                                                     .paragraphStyle: titleStyle])
            NSColor.secondaryLabelColor.withAlphaComponent(progress * 0.5).setFill()
            for x: CGFloat in [10, 20, 30] {
                NSBezierPath(ovalIn: NSRect(x: x, y: size.height - 17, width: 6, height: 6)).fill()
            }
            tabImage?.draw(in: NSRect(x: 0, y: size.height - tabSize.height,
                                     width: size.width, height: tabSize.height),
                           from: .zero, operation: .sourceOver, fraction: 1 - progress)
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        image.unlockFocus()
        if progress >= 1 {
            finalImage = image
        }
        return image
    }

    private static func snapshot(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}
