import AppKit
import SwiftUI

enum TerminalTabColor: Int, CaseIterable, Codable {
    case none
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite

    var localizedName: String {
        switch self {
        case .none:
            return "None"
        case .blue:
            return "Blue"
        case .purple:
            return "Purple"
        case .pink:
            return "Pink"
        case .red:
            return "Red"
        case .orange:
            return "Orange"
        case .yellow:
            return "Yellow"
        case .green:
            return "Green"
        case .teal:
            return "Teal"
        case .graphite:
            return "Graphite"
        }
    }

    var displayColor: NSColor? {
        switch self {
        case .none:
            return nil
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .pink:
            return .systemPink
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .teal:
            if #available(macOS 13.0, *) {
                return .systemMint
            } else {
                return .systemTeal
            }
        case .graphite:
            return .systemGray
        }
    }

    func swatchImage(selected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)

            if let fillColor = self.displayColor {
                fillColor.setFill()
                circlePath.fill()
            } else {
                NSColor.clear.setFill()
                circlePath.fill()
                NSColor.quaternaryLabelColor.setStroke()
                circlePath.lineWidth = 1
                circlePath.stroke()
            }

            if self == .none {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.midY))
                slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.midY))
                slash.lineWidth = 1.5
                NSColor.systemRed.setStroke()
                slash.stroke()
            }

            if selected {
                let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                highlight.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                highlight.stroke()
            }

            return true
        }
    }
}

// MARK: - Menu View

/// A SwiftUI view displaying a single-row color palette for tab color selection.
/// Used as a custom view inside an NSMenuItem on macOS 13.
struct TabColorMenuView: View {
    /// The palette is a single row in enum order: None first, then colors.
    /// Color names appear only in tooltips/accessibility, never as visible entries.
    static let paletteColors: [TerminalTabColor] = TerminalTabColor.allCases

    @State private var currentSelection: TerminalTabColor
    @FocusState private var focusedColor: TerminalTabColor?
    let onSelect: (TerminalTabColor) -> Void

    init(selectedColor: TerminalTabColor, onSelect: @escaping (TerminalTabColor) -> Void) {
        self._currentSelection = State(initialValue: selectedColor)
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tab Color")
                .padding(.bottom, 2)

            HStack(spacing: 2) {
                ForEach(Self.paletteColors, id: \.self) { color in
                    TabColorSwatch(
                        color: color,
                        isSelected: color == currentSelection,
                        focusedColor: $focusedColor
                    ) {
                        currentSelection = color
                        onSelect(color)
                    }
                }
            }
            .onMoveCommand { direction in
                moveFocus(direction)
            }
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let colors = Self.paletteColors
        let anchor = focusedColor ?? currentSelection
        guard let index = colors.firstIndex(of: anchor) else { return }
        switch direction {
        case .left:
            focusedColor = colors[(index - 1 + colors.count) % colors.count]
        case .right:
            focusedColor = colors[(index + 1) % colors.count]
        default:
            break
        }
    }

    /// Leading padding to align with the menu's icon gutter.
    /// macOS 26 introduced icons in menus, requiring additional padding.
    private static var leadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 40
        } else {
            return 12
        }
    }
}

/// A single color swatch button in the tab color palette.
private struct TabColorSwatch: View {
    let color: TerminalTabColor
    let isSelected: Bool
    var focusedColor: FocusState<TerminalTabColor?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if color == .none {
                    Image(nsImage: color.swatchImage(selected: isSelected))
                } else if let displayColor = color.displayColor {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Color(nsColor: displayColor))
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focusedColor, equals: color)
        .help(color.localizedName)
        .accessibilityLabel(color.localizedName)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Compact Palette Menu

/// Fixed-size native buttons avoid AppKit's expanding color-palette cells.
func makeProjectTabColorMenu(
    selected: TerminalTabColor,
    onSelect: @escaping (TerminalTabColor) -> Void
) -> NSMenu {
    let menu = NSMenu(title: "Tab Color")
    let handler = TabColorPaletteActionHandler(onSelect: onSelect)
    handler.menu = menu
    let row = TabColorPaletteRowView(selected: selected, handler: handler)
    let item = NSMenuItem()
    row.frame = NSRect(origin: .zero, size: row.fittingSize)
    item.view = row
    menu.addItem(item)
    return menu
}

/// Handles swatch clicks for the native palette menu. `NSControl.target` is weak,
/// so the row view retains this for the lifetime of the menu.
final class TabColorPaletteActionHandler: NSObject {
    weak var menu: NSMenu?
    let onSelect: (TerminalTabColor) -> Void

    init(onSelect: @escaping (TerminalTabColor) -> Void) {
        self.onSelect = onSelect
    }

    @objc func selectSwatch(_ sender: NSButton) {
        guard let color = TerminalTabColor(rawValue: sender.tag) else { return }
        onSelect(color)
        var root = sender.enclosingMenuItem?.menu ?? menu
        while let parent = root?.supermenu {
            root = parent
        }
        root?.cancelTracking()
    }
}

/// Horizontal row of swatch buttons for the native palette menu.
/// Retains its action handler and moves keyboard focus between swatches
/// on Left/Right arrows once a swatch is focused (Tab-focusable otherwise).
final class TabColorPaletteRowView: NSStackView {
    private let handler: TabColorPaletteActionHandler

    init(selected: TerminalTabColor, handler: TabColorPaletteActionHandler) {
        self.handler = handler
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        setAccessibilityLabel("Tab Color")
        for color in TerminalTabColor.allCases {
            let button = NSButton(
                image: color.swatchImage(selected: color == selected),
                target: handler,
                action: #selector(TabColorPaletteActionHandler.selectSwatch(_:)))
            button.tag = color.rawValue
            button.setAccessibilityValue(color == selected ? "Selected" : "")
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.focusRingType = .exterior
            button.refusesFirstResponder = false
            button.toolTip = color.localizedName
            button.setAccessibilityLabel(color == selected ? "\(color.localizedName), selected" : color.localizedName)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func keyDown(with event: NSEvent) {
        let delta: Int
        switch event.keyCode {
        case 123:
            delta = -1
        case 124:
            delta = 1
        default:
            super.keyDown(with: event)
            return
        }
        let buttons = arrangedSubviews.compactMap { $0 as? NSButton }
        guard !buttons.isEmpty else {
            super.keyDown(with: event)
            return
        }
        let current = buttons.firstIndex(where: { $0 === window?.firstResponder })
        let next: NSButton
        if let current {
            next = buttons[(current + delta + buttons.count) % buttons.count]
        } else {
            next = delta > 0 ? buttons[0] : buttons[buttons.count - 1]
        }
        window?.makeFirstResponder(next)
    }
}
