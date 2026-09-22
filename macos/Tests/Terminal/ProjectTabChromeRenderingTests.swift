import AppKit
import SwiftUI
import XCTest
@testable import Ghostty

/// Light/dark review fixtures of the production SwiftUI components, not a
/// separate HTML mock-up. Contrast, reduce-transparency, and inactive states
/// can't be injected into an off-screen NSHostingView, so they aren't claimed
/// here. Synthetic titles and an empty thumbnail keep terminal content out of
/// CI.
final class ProjectTabChromeRenderingTests: XCTestCase {
    @MainActor
    func testProjectDragPreviewKeepsHighlightedTextReadableInBothAppearances() throws {
        for dark in [false, true] {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            let image = try XCTUnwrap(ProjectSidebarDragPreview.image(
                project: TerminalProject(name: "Dragged project"), directory: "~/Projects/Toastty",
                size: NSSize(width: 220, height: 60), appearance: appearance))
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            // Check the actual bitmap, not just SwiftUI's requested colors.
            // Vibrant row snapshots previously turned the glyphs black.
            let scale = CGFloat(bitmap.pixelsWide) / 220
            for band in [10..<32, 32..<54] {
                var readablePixels = 0
                for y in Int(CGFloat(band.lowerBound) * scale)..<Int(CGFloat(band.upperBound) * scale) {
                    for x in Int(40 * scale)..<Int(180 * scale) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.65 {
                            readablePixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(readablePixels, 20, "Unreadable drag text in \(dark ? "dark" : "light") mode")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "project-drag-dark" : "project-drag-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testChromeLightAndDarkFixtures() throws {
        for dark in [false, true] {
            let name = dark ? "tabs-dark" : "tabs-light"
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 360),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            defer {
                window.contentView = nil
                window.close()
            }
            let row = TabSidebarModel.Row(
                window: window, project: TerminalProject(),
                title: "Build · उत्पादन", pwd: "~/Projects/Toastty/Long Directory/Sources")
            let fixture = ChromeFixture(row: row)
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

private struct ChromeFixture: View {
    let row: TabSidebarModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected, hovered, inactive, and keyboard focus")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ProjectTabCell(row: row, isSelected: true, onSelect: { _ in },
                               showSeparator: false, shortcutHint: "⌘1", width: 135)
                ProjectTabCell(row: row, isSelected: false, onSelect: { _ in },
                               showSeparator: false, width: 135, isHovered: true)
                ProjectTabCell(row: row, isSelected: false, onSelect: { _ in },
                               showSeparator: false, width: 135)
                Text("Focus")
                    .font(.system(size: 13))
                    .frame(width: 135, height: ProjectTabStripView.cellHeight)
                    .background { ProjectTabChrome(isSelected: true, isFocused: true) }
            }
            .padding(.horizontal, ProjectTabStripView.railPadding / 2)
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
