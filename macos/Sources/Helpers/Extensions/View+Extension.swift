import SwiftUI

extension View {
    func innerShadow<S: Shape, ST: ShapeStyle>(
        using shape: S = Rectangle(),
        stroke: ST = Color.black,
        width: CGFloat = 6,
        blur: CGFloat = 6
    ) -> some View {
        return self
            .overlay(
                shape
                    .stroke(stroke, lineWidth: width)
                    .blur(radius: blur)
                    .mask(shape)
            )
    }

    /// Reduce-motion-aware animation. Returns `self` unanimated when Reduce
    /// Motion is enabled, otherwise applies `animation` for `value`.
    /// Use for all non-essential SwiftUI motion (pulses, slides, progress).
    func motionAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }

    /// Shared overlay-card treatment for floating badges, bars and popovers.
    /// Single source for corner radius, border and shadow so the ~9 overlay
    /// styles stay consistent. Increase Contrast / Reduce Transparency fall
    /// back to an opaque fill with a stronger border.
    func toasttyOverlayCard(cornerRadius: CGFloat = 8) -> some View {
        modifier(ToasttyOverlayCardModifier(cornerRadius: cornerRadius))
    }
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Applies the configured animation unless Reduce Motion is enabled.
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct ToasttyOverlayCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Applies the shared overlay-card appearance for current accessibility settings.
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.3), lineWidth: 1))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
    }
}

extension View {
    func pointerStyleFromCursor(_ cursor: NSCursor) -> some View {
        if #available(macOS 15.0, *) {
            return self.pointerStyle(.image(
                Image(nsImage: cursor.image),
                hotSpot: .init(x: cursor.hotSpot.x, y: cursor.hotSpot.y)
            ))
        } else {
            return self
        }
    }
}
