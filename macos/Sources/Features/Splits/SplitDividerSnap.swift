import Foundation

/// Point-based capture and release distances make snapping feel consistent
/// in both a small pane and a large window. The wider release distance avoids
/// jitter at a snap boundary; Option bypasses snapping without ending a drag.
enum SplitDividerSnap {
    static let ratios: [CGFloat] = [1 / 3, 0.5, 2 / 3]

    struct Result {
        let ratio: CGFloat
        let target: CGFloat?
    }

    static func resolve(position: CGFloat, extent: CGFloat, previous: CGFloat?, enabled: Bool) -> Result {
        guard extent.isFinite, extent > 20, position.isFinite else {
            return Result(ratio: 0.5, target: nil)
        }
        let minimum = min(10, extent / 2)
        let clamped = min(max(minimum, position), extent - minimum)
        if enabled {
            if let previous, ratios.contains(previous),
               previous * extent >= minimum, (1 - previous) * extent >= minimum,
               abs(clamped - previous * extent) <= 10 {
                return Result(ratio: previous, target: previous)
            }
            if let nearest = ratios.min(by: { abs(clamped - $0 * extent) < abs(clamped - $1 * extent) }),
               nearest * extent >= minimum, (1 - nearest) * extent >= minimum,
               abs(clamped - nearest * extent) <= 6 {
                return Result(ratio: nearest, target: nearest)
            }
        }
        return Result(ratio: clamped / extent, target: nil)
    }
}
