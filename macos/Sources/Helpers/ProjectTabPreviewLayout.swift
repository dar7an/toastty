import Foundation

/// Screen-space placement independent of AppKit so edge cases stay testable.
/// Prefer below the tab, flip above when needed, and only then clamp. Clamping
/// immediately can cover the tab that the pointer is trying to identify.
enum ProjectTabPreviewLayout {
    static let gap: CGFloat = 8

    static func frame(size: CGSize, below anchor: CGRect, on screen: CGRect) -> CGRect {
        let values = [size.width, size.height, anchor.origin.x, anchor.origin.y,
                      anchor.size.width, anchor.size.height, screen.origin.x, screen.origin.y,
                      screen.size.width, screen.size.height]
        guard values.allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              screen.size.width > 0, screen.size.height > 0,
              anchor.size.width >= 0, anchor.size.height >= 0 else { return .zero }

        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(anchor.midX - width / 2, screen.minX), screen.maxX - width)
        let below = anchor.minY - gap - height
        let above = anchor.maxY + gap
        let preferredY: CGFloat
        if below >= screen.minY {
            preferredY = below
        } else if above + height <= screen.maxY {
            preferredY = above
        } else {
            let roomBelow = max(0, anchor.minY - gap - screen.minY)
            let roomAbove = max(0, screen.maxY - anchor.maxY - gap)
            preferredY = roomBelow >= roomAbove ? below : above
        }
        let y = min(max(preferredY, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
