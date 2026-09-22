import SwiftUI

extension Ghostty {
    /// A floating pane grip revealed by hovering its drag target.
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

        private var showsGrip: Bool {
            dragHandle == .always || isHovering || isDragging
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
                            contrast == .increased ? 0.85 : 0.65))
                        .frame(width: 32, height: 3)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .opacity(showsGrip ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .motionAnimation(.easeOut(duration: 0.12), value: showsGrip)
            }
        }
    }
}
