import SwiftUI

extension Ghostty {
    /// A dedicated pane header keeps the drag target clear of terminal text.
    struct SurfaceGrabHandle: View {
        let surfaceView: SurfaceView
        let isSplit: Bool
        let dragHandle: Ghostty.Config.DragHandle

        @State private var isHovering = false
        @State private var isDragging = false
        @Environment(\.colorSchemeContrast) private var contrast

        private var isVisible: Bool {
            switch dragHandle {
            case .always: true
            case .never: false
            case .auto: isSplit
            }
        }

        var body: some View {
            if isVisible {
                ZStack {
                    SurfaceDragSource(
                        surfaceView: surfaceView,
                        isDragging: $isDragging,
                        isHovering: $isHovering)
                        .frame(width: 64, height: 18)
                        .contentShape(Rectangle())
                        .help("Drag to move this terminal pane")
                        .accessibilityLabel("Move Terminal Pane")

                    Capsule()
                        .fill(Color.primary.opacity(
                            contrast == .increased ? 0.85 : (isHovering || isDragging ? 0.65 : 0.35)))
                        .frame(width: 32, height: 3)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .motionAnimation(.easeOut(duration: 0.12), value: isHovering)
            }
        }
    }
}
