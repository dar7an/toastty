import AppKit

/// Preview a reorder without changing AppKit's tab group until mouse-up.
/// The tab follows the pointer directly; only neighboring tabs animate.
@MainActor
final class ProjectTabReorderGesture {
    private struct Cell {
        weak var view: NSView?
        let index: Int
        let width: CGFloat
    }
    private unowned let source: ProjectTabCellHostingView
    private let cells: [Cell]
    private let sourceIndex: Int
    private let widths: [CGFloat]
    private var escapeMonitor: Any?
    private(set) var targetIndex: Int
    private var offsets: [ObjectIdentifier: CGFloat] = [:]
    var onCancel: (() -> Void)?

    init?(source: ProjectTabCellHostingView) {
        guard let controller = source.rootView.row.window.windowController as? TerminalController,
              let sourceIndex = controller.projectTabWindows.firstIndex(of: source.rootView.row.window),
              source.bounds.width > 0 else { return nil }
        var ancestor = source.superview
        while let view = ancestor, !(view is ProjectTabStripHostingView) { ancestor = view.superview }
        guard let strip = ancestor else { return nil }
        let windows = controller.projectTabWindows
        func tabCells(in view: NSView) -> [ProjectTabCellHostingView] {
            view.subviews.flatMap { child in
                (child as? ProjectTabCellHostingView).map { [$0] } ?? tabCells(in: child)
            }
        }
        self.source = source
        self.sourceIndex = sourceIndex
        self.targetIndex = sourceIndex
        let cells = tabCells(in: strip).compactMap { cell -> Cell? in
            guard let index = windows.firstIndex(of: cell.rootView.row.window) else { return nil }
            // Translate the representable's wrapper so its own clipping bounds
            // move with the tab, including the system glass and hover content.
            return Cell(
                view: cell.superview ?? cell,
                index: index,
                width: cell.bounds.width)
        }
        var widths = Array(repeating: source.bounds.width, count: windows.count)
        for cell in cells { widths[cell.index] = cell.width }
        self.cells = cells
        self.widths = widths
        for cell in cells {
            cell.view?.wantsLayer = true
            if cell.index == sourceIndex { cell.view?.layer?.zPosition = 1 }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            self.finish(commit: false)
            self.onCancel?()
            return nil
        }
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    static func destination(source: Int, translation: CGFloat, widths: [CGFloat]) -> Int {
        guard widths.indices.contains(source),
              widths.allSatisfy({ $0 > 0 && $0.isFinite }),
              translation.isFinite else { return source }
        var destination = source
        if translation > 0 {
            var threshold: CGFloat = 0
            for index in (source + 1)..<widths.count {
                threshold += (widths[index - 1] + widths[index]) / 2
                if translation < threshold { break }
                destination = index
            }
        } else if translation < 0, source > 0 {
            var threshold: CGFloat = 0
            for index in stride(from: source - 1, through: 0, by: -1) {
                threshold -= (widths[index + 1] + widths[index]) / 2
                if translation > threshold { break }
                destination = index
            }
        }
        return destination
    }

    static func neighborOffset(index: Int, source: Int, destination: Int, width: CGFloat) -> CGFloat {
        if source < destination, index > source, index <= destination { return -width }
        if source > destination, index >= destination, index < source { return width }
        return 0
    }

    func update(translation: CGFloat) {
        targetIndex = Self.destination(
            source: sourceIndex,
            translation: translation,
            widths: widths)
        let minimum = -widths.prefix(sourceIndex).reduce(0, +)
        let maximum = widths.dropFirst(sourceIndex + 1).reduce(0, +)
        let clamped = min(maximum, max(minimum, translation))
        let sourceWidth = widths[sourceIndex]
        for cell in cells {
            let offset = cell.index == sourceIndex ? clamped : Self.neighborOffset(
                index: cell.index,
                source: sourceIndex,
                destination: targetIndex,
                width: sourceWidth)
            if let view = cell.view { setOffset(offset, on: view, animated: cell.index != sourceIndex) }
        }
    }

    func finish(commit: Bool, animated: Bool = true) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        for cell in cells {
            if let view = cell.view { setOffset(0, on: view, animated: !commit && animated) }
            cell.view?.layer?.zPosition = 0
        }
        guard commit,
              let controller = source.rootView.row.window.windowController as? TerminalController else { return }
        TerminalLayoutCoordinator.shared.reorderTab(controller.projectTabID, toProjectIndex: targetIndex)
    }

    private func setOffset(_ value: CGFloat, on view: NSView, animated: Bool) {
        let id = ObjectIdentifier(view)
        guard offsets[id, default: 0] != value, let layer = view.layer else { return }
        offsets[id] = value
        let key = "transform.translation.x"
        let previous = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        layer.removeAnimation(forKey: "tabReorder")
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CASpringAnimation(keyPath: key)
            animation.fromValue = previous
            animation.toValue = value
            animation.mass = 1
            animation.stiffness = 400
            animation.damping = 40
            animation.duration = 0.25
            layer.add(animation, forKey: "tabReorder")
        }
        CATransaction.commit()
    }
}
