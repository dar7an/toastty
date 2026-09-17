import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// Divider color
    let dividerColor: Color

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    private var splitterVisibleSize: CGFloat {
        ProjectChrome.hairline(displayScale: displayScale)
    }
    private let splitterInvisibleSize: CGFloat = 6
    @Environment(\.displayScale) private var displayScale

    @State private var coordinateSpaceID = UUID()
    @State private var dragStartRatio: CGFloat?
    @State private var snapTarget: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: snapTarget == nil ? dividerColor : .accentColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size))
                    .help("Drag to resize; hold Option to avoid snapping. Double-click to equalize splits.")
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .coordinateSpace(name: coordinateSpaceID)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        // A one-point threshold leaves ordinary double-clicks available to
        // the equalize gesture while starting a resize without a visible lag.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceID))
            .onChanged { gesture in
                if dragStartRatio == nil { dragStartRatio = split }
                let extent = direction == .horizontal ? size.width : size.height
                let translation = direction == .horizontal ? gesture.translation.width : gesture.translation.height
                let result = SplitDividerSnap.resolve(
                    position: (dragStartRatio ?? split) * extent + translation,
                    extent: extent, previous: snapTarget,
                    enabled: !(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false))
                if result.target != nil, result.target != snapTarget {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                // Direct manipulation must never trail the pointer or inherit
                // an animation from surrounding chrome. Preserve the grab offset.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    snapTarget = result.target
                    if split != result.ratio { split = result.ratio }
                }
            }
            .onEnded { _ in
                dragStartRatio = nil
                snapTarget = nil
            }
    }

    /// Calculates the bounding rect for the left view.
    private func leftRect(for size: CGSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            result.size.width *= split
            result.size.width -= splitterVisibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: self.resizeIncrements.width)

        case .vertical:
            result.size.height *= split
            result.size.height -= splitterVisibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: self.resizeIncrements.height)
        }

        return result
    }

    /// Calculates the bounding rect for the right view.
    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            // For horizontal layouts we offset the starting X by the left rect
            // and make the width fit the remaining space.
            result.origin.x += leftRect.size.width
            result.origin.x += splitterVisibleSize
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += splitterVisibleSize
            result.size.height -= result.origin.y
        }

        return result
    }

    /// Calculates the point at which the splitter should be rendered.
    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        // The divider is positioned at the center of the `splitterVisibleSize`-wide
        // gap. The gap sits entirely to the right/below `leftRect`'s
        // integer-floored edge so the hairline covers exactly one physical
        // pixel — a line centered on an integer-point boundary straddles two
        // pixels on Retina and renders soft.
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.size.width + splitterVisibleSize / 2, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height + splitterVisibleSize / 2)
        }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left split"
        case .vertical:
            return "Top split"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right split"
        case .vertical:
            return "Bottom split"
        }
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}
