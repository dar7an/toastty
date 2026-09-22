import SwiftUI

/// Capsule tabs sit inside the rounded rail's two-point inset. Selection,
/// hover, press, and keyboard focus share the same shape.
struct ProjectTabChrome: View {
    var isSelected = false
    var isHovered = false
    var isPressed = false
    var isFocused = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    private var shape: Capsule { ProjectTabStripView.cellShape }

    private var fill: Color {
        if isSelected {
            // Light: an opaque raised card. Dark: `controlBackgroundColor`
            // sits below the titlebar material and reads as recessed, so
            // lift the selected tab with a light wash instead.
            if colorScheme == .dark {
                return Color.white.opacity(activeState == .inactive ? 0.07 : 0.12)
            }
            return Color(nsColor: activeState == .inactive ? .windowBackgroundColor : .controlBackgroundColor)
        }
        return isHovered ? Color.primary.opacity(contrast == .increased ? 0.12 : 0.06) : .clear
    }

    var body: some View {
        shape.fill(fill)
            .overlay {
                if isPressed {
                    shape.fill(Color.primary.opacity(0.08))
                }
            }
            .overlay {
                if isSelected || (isHovered && contrast == .increased) {
                    shape.strokeBorder(
                        contrast == .increased ? Color.primary : ProjectChrome.separatorColor,
                        lineWidth: contrast == .increased ? 1 : ProjectChrome.hairline(displayScale: displayScale))
                }
            }
            .overlay {
                if isFocused {
                    shape.inset(by: 1)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A continuous recessed capsule groups the tabs. The 32-point rail wraps
/// 28-point tab capsules with a concentric two-point inset on every side.
struct ProjectTabRailBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .controlBackgroundColor)
            } else {
                VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow)
            }
        }
        .overlay(.primary.opacity(0.04))
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(
                ProjectChrome.separatorColor,
                lineWidth: contrast == .increased ? 1 : ProjectChrome.hairline(displayScale: displayScale))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
