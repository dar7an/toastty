import AppKit
import SwiftUI
import XCTest
@testable import Ghostty

/// Render the production SwiftUI components, not a separate HTML mock-up.
/// Synthetic titles and an empty thumbnail keep terminal content out of CI.
final class ProjectTabChromeRenderingTests: XCTestCase {
    @MainActor
    func testChromeAppearanceMatrix() throws {
        for dark in [false, true] {
            for mode in ["standard", "contrast", "opaque", "inactive"] {
                let name = "tabs-\(dark ? "dark" : "light")-\(mode)"
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 360),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                // Contrast is read-only in SwiftUI's environment. Let the
                // native appearance supply both color scheme and contrast.
                let appearanceName: NSAppearance.Name
                if mode == "contrast" {
                    appearanceName = dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
                } else {
                    appearanceName = dark ? .darkAqua : .aqua
                }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                defer {
                    window.contentView = nil
                    window.close()
                }
                let row = TabSidebarModel.Row(
                    window: window, project: TerminalProject(),
                    title: "Build · उत्पादन", pwd: "~/Projects/Toastty/Long Directory/Sources")
                let fixture = ChromeFixture(row: row)
                    .environment(\.accessibilityReduceTransparency, mode == "opaque")
                    .environment(\.accessibilityReduceMotion, true)
                    .environment(\.controlActiveState, mode == "inactive" ? .inactive : .key)
                let host = NSHostingView(rootView: fixture)
                host.appearance = window.appearance
                window.contentView = host
                host.frame = CGRect(x: 0, y: 0, width: 620, height: 360)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 620)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 360)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

private struct ChromeFixture: View {
    let row: TabSidebarModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected, hovered, compact, and keyboard focus")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ProjectTabCell(row: row, isSelected: true, onSelect: { _ in },
                               showSeparator: false, shortcutHint: "⌘1", width: 190)
                ProjectTabCell(row: row, isSelected: false, onSelect: { _ in },
                               showSeparator: false, width: 190, isHovered: true)
                ProjectTabCell(row: row, isSelected: false, onSelect: { _ in },
                               showSeparator: false, width: 54)
                Text("Focus")
                    .font(.system(size: 13))
                    .frame(width: 100, height: ProjectTabStripView.cellHeight)
                    .background { ProjectTabChrome(isSelected: true, isFocused: true) }
            }
            .padding(.vertical, 2)
            .background { ProjectTabRailBackground() }
            HStack(alignment: .top, spacing: 16) {
                ProjectTabHoverCard(title: row.title, directory: row.pwd, snapshot: nil, shortcutHint: "⌘2")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Small-screen preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProjectTabHoverCard(title: row.title, directory: row.pwd, snapshot: nil,
                                        shortcutHint: "⌘2", size: CGSize(width: 180, height: 100))
                    Text("Press")
                        .font(.system(size: 13))
                        .frame(width: 120, height: ProjectTabStripView.cellHeight)
                        .background { ProjectTabChrome(isHovered: true, isPressed: true) }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 360, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
