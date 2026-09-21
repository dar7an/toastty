import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The terminal layout item being dragged. A tab payload represents
        /// its complete split tree; a surface payload represents one leaf.
        let payload: TerminalLayoutDragPayload

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone

        init(
            payload: TerminalLayoutDragPayload,
            destination: Ghostty.SurfaceView,
            zone: TerminalSplitDropZone
        ) {
            self.payload = payload
            self.destination = destination
            self.zone = zone
        }

        init(
            payload: Ghostty.SurfaceView,
            destination: Ghostty.SurfaceView,
            zone: TerminalSplitDropZone
        ) {
            self.init(payload: .surface(payload.id), destination: destination, zone: zone)
        }
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.configuredSplitDividerColor ?? ProjectChrome.separatorColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    @StateObject private var dragSession = TerminalLayoutDragSession()
    @ObservedObject private var tabDragFeedback = ProjectTabDragSession.feedback

    var body: some View {
        GeometryReader { geometry in
            Ghostty.InspectableSurface(
                surfaceView: surfaceView,
                isSplit: isSplit)
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId, .toasttyTerminalLayoutID], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            session: dragSession,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                TerminalSplitDropPreview(zone: previewZone, size: geometry.size)
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal split")
        }
    }

    private var previewZone: TerminalSplitDropZone? {
        if let target = tabDragFeedback.target, target.surfaceID == surfaceView.id {
            return target.zone
        }
        guard !isSelfDragging, case .dropping(let zone) = dropState,
              let payload = dragSession.payload,
              TerminalLayoutCoordinator.shared.proposal(for: payload, on: surfaceView, zone: zone)?.isValid == true
        else { return nil }
        return zone
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let session: TerminalLayoutDragSession
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId, .toasttyTerminalLayoutID])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            session.begin(info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId]))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping(let previous) = dropState else { return DropProposal(operation: .forbidden) }
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize, preferring: previous)
            dropState = .dropping(zone)
            let valid = session.payload.map {
                TerminalLayoutCoordinator.shared.proposal(for: $0, on: destinationSurface, zone: zone)?.isValid == true
            } ?? false
            return DropProposal(operation: valid ? .move : .forbidden)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
            session.end()
        }

        func performDrop(info: DropInfo) -> Bool {
            let previous: TerminalSplitDropZone? = if case .dropping(let zone) = dropState { zone } else { nil }
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize, preferring: previous)
            dropState = .idle

            if let payload = session.payload {
                guard TerminalLayoutCoordinator.shared.proposal(
                    for: payload, on: destinationSurface, zone: zone)?.isValid == true else { return false }
                session.end()
                action(.drop(.init(payload: payload, destination: destinationSurface, zone: zone)))
                return true
            }

            // A fast drop can land before the session's asynchronous payload
            // publish; load the providers directly and commit on completion.
            return session.finishDrop(
                info.itemProviders(for: [.toasttyTerminalLayoutID, .ghosttySurfaceId])
            ) { payload in
                guard TerminalLayoutCoordinator.shared.proposal(
                    for: payload, on: self.destinationSurface, zone: zone)?.isValid == true else { return }
                self.action(.drop(.init(payload: payload, destination: self.destinationSurface, zone: zone)))
            }
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(
        at point: CGPoint,
        in size: CGSize,
        preferring previous: TerminalSplitDropZone? = nil
    ) -> TerminalSplitDropZone {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              point.x.isFinite, point.y.isFinite else { return previous ?? .left }
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        // Keep the visible destination stable near a diagonal boundary. The
        // same preference is used on release, so the preview and drop agree.
        if let previous {
            let previousDistance: CGFloat = switch previous {
            case .left: distToLeft
            case .right: distToRight
            case .top: distToTop
            case .bottom: distToBottom
            }
            let tolerance = min(0.04, 8 / min(size.width, size.height))
            if previousDistance - minDist <= tolerance { return previous }
        }

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    func previewFrame(in size: CGSize) -> CGRect {
        switch self {
        case .top:
            CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .left:
            CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        }
    }
}

private struct TerminalSplitDropPreview: View {
    let zone: TerminalSplitDropZone?
    let size: CGSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let zone {
                let frame = zone.previewFrame(in: size).insetBy(dx: 5, dy: 5)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.65), lineWidth: 2)
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .offset(x: frame.minX, y: frame.minY)
                    .id(zone)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Cross-fade only the preview; never animate terminal layout or input.
        .motionAnimation(.easeOut(duration: 0.15), value: zone)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
