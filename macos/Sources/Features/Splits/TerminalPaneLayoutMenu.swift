import AppKit
import GhosttyKit

/// Native menus with evenly spaced pane buttons, tooltips and VoiceOver.
enum TerminalPaneLayoutMenu {
    static func append(to menu: NSMenu, surface: Ghostty.SurfaceView) {
        let controller = BaseTerminalController.controller(owning: surface)
        append(to: menu, target: surface, hasSplits: controller?.surfaceTree.isSplit == true,
               isZoomed: controller?.surfaceTree.zoomed != nil)
    }

    /// Construct the native menu separately from live terminal ownership.
    /// The target is a pane responder; its selectors stay explicit so actions
    /// never fall through to whichever other pane currently has focus.
    static func append(to menu: NSMenu, target: NSObject, hasSplits: Bool, isZoomed: Bool) {
        appendRow(to: menu, title: "Split Pane", target: target, actions: [
            ("Split Left", "rectangle.lefthalf.inset.filled", #selector(Ghostty.SurfaceView.splitLeft(_:))),
            ("Split Right", "rectangle.righthalf.inset.filled", #selector(Ghostty.SurfaceView.splitRight(_:))),
            ("Split Up", "rectangle.tophalf.inset.filled", #selector(Ghostty.SurfaceView.splitUp(_:))),
            ("Split Down", "rectangle.bottomhalf.inset.filled", #selector(Ghostty.SurfaceView.splitDown(_:)))
        ])

        guard hasSplits else { return }
        appendRow(to: menu, title: "Arrange Panes", target: target, actions: [
            (isZoomed ? "Show All Panes" : "Zoom Pane",
             isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
             #selector(Ghostty.SurfaceView.zoomPaneFromMenu(_:))),
            ("Equalize Panes", "rectangle.split.2x2", #selector(Ghostty.SurfaceView.equalizePanesFromMenu(_:)))
        ])
    }

    private static func appendRow(
        to menu: NSMenu,
        title: String,
        target: NSObject,
        actions: [(title: String, symbol: String, selector: Selector)]
    ) {
        let row = NSMenu(title: title)
        for action in actions {
            let item = NSMenuItem(title: action.title, action: action.selector, keyEquivalent: "")
            // Bind to the clicked pane, even when another pane has focus.
            item.target = target
            item.toolTip = action.title
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            row.addItem(item)
        }
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: title))
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            // NSMenu's palette presentation fixes the selection row height,
            // leaving larger layout symbols flush with its highlight. Native
            // buttons in a sized menu view give both glyphs and targets room.
            let view = PaneLayoutPaletteRowView(items: row.items)
            view.setAccessibilityLabel(title)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            item.view = view
            menu.addItem(item)
        } else {
            // Preserve standard keyboard-accessible menu actions on macOS 13.
            for item in row.items {
                row.removeItem(item)
                menu.addItem(item)
            }
        }
    }
}

final class PaneLayoutPaletteRowView: NSStackView {
    init(items: [NSMenuItem]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        for item in items {
            let button = PaneLayoutMenuButton(item: item)
            button.widthAnchor.constraint(equalToConstant: 48).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        let buttons = arrangedSubviews.compactMap { $0 as? NSButton }
        guard !buttons.isEmpty, event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
        let delta = event.keyCode == 123 ? -1 : 1
        let current = buttons.firstIndex { $0 === window?.firstResponder }
        let next = current.map { ($0 + delta + buttons.count) % buttons.count }
            ?? (delta > 0 ? 0 : buttons.count - 1)
        window?.makeFirstResponder(buttons[next])
    }
}

/// Keep NSButton's accessibility, keyboard activation and press tracking;
/// draw the compact rounded highlight used by macOS arrangement controls.
final class PaneLayoutMenuButton: NSButton {
    let menuAction: NSMenuItem
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(item: NSMenuItem) {
        menuAction = item
        super.init(frame: .zero)
        image = item.image
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        (cell as? NSButtonCell)?.highlightsBy = []
        focusRingType = .exterior
        refusesFirstResponder = false
        toolTip = item.toolTip
        setAccessibilityLabel(item.title)
        target = self
        action = #selector(invokeMenuAction)
    }

    required init?(coder: NSCoder) { nil }

    // Borderless buttons still inherit the bezel's alignment insets. Our
    // drawn highlight should occupy exactly the constrained click target.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                 owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        contentTintColor = highlighted ? .alternateSelectedControlTextColor : .labelColor
        super.draw(dirtyRect)
    }

    @objc private func invokeMenuAction() {
        guard let target = menuAction.target, let action = menuAction.action else { return }
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        NSApp.sendAction(action, to: target, from: self)
    }
}

extension Ghostty.SurfaceView {
    @objc func zoomPaneFromMenu(_ sender: Any?) {
        guard let surface else { return }
        let action = "toggle_split_zoom"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc func equalizePanesFromMenu(_ sender: Any?) {
        guard let surface else { return }
        ghostty_surface_split_equalize(surface)
    }
}
