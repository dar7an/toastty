import SwiftUI

/// Chrome is deliberately quiet: an opaque selected surface, a fine edge,
/// and immediate pointer feedback. The system toolbar owns the material;
/// nesting glass inside glass makes terminal navigation harder to read.
struct ProjectTabChrome: View {
    var isSelected = false
    var isHovered = false
    var isPressed = false
    var isFocused = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ProjectChrome.tabCornerRadius, style: .continuous)
    }

    private var fill: Color {
        if isSelected {
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

/// A single attached surface replaces the capsule-within-a-capsule track.
/// Native vibrancy stays in the toolbar, never behind selected-tab text.
struct ProjectTabRailBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow)
            }
        }
        .overlay(alignment: .bottom) {
            ProjectChrome.separatorColor
                .frame(height: contrast == .increased ? 1 : ProjectChrome.hairline(displayScale: displayScale))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
