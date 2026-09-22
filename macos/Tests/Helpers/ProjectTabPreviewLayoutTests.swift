import Foundation
import Testing
@testable import Ghostty

struct ProjectTabPreviewLayoutTests {
    private let size = CGSize(width: 280, height: 196)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func prefersBelowWithAnEightPointGap() {
        let anchor = CGRect(x: 400, y: 800, width: 190, height: 28)
        let frame = ProjectTabPreviewLayout.frame(size: size, below: anchor, on: screen)
        #expect(frame.midX == anchor.midX)
        #expect(frame.maxY == anchor.minY - ProjectTabPreviewLayout.gap)
        #expect(frame.size == size)
    }

    @Test func flipsAboveRatherThanCoveringTheHoveredTab() {
        let anchor = CGRect(x: 400, y: 50, width: 190, height: 28)
        let frame = ProjectTabPreviewLayout.frame(size: size, below: anchor, on: screen)
        #expect(frame.minY == anchor.maxY + ProjectTabPreviewLayout.gap)
        #expect(!frame.intersects(anchor))
        #expect(screen.contains(frame))
    }

    @Test func fitsSmallScreensWithoutClippingTheCardContent() {
        let smallScreen = CGRect(x: -100, y: 40, width: 180, height: 100)
        let anchor = CGRect(x: -50, y: 80, width: 54, height: 28)
        let frame = ProjectTabPreviewLayout.frame(size: size, below: anchor, on: smallScreen)
        #expect(frame == smallScreen)
    }

    @Test func supportsNegativeAndVerticallyOffsetDisplays() {
        for origin in [CGPoint(x: -1920, y: 80), CGPoint(x: 100, y: -1200)] {
            let display = CGRect(origin: origin, size: screen.size)
            for x: CGFloat in [0, 720, 1420] {
                let anchor = CGRect(x: origin.x + x, y: origin.y + 820, width: 54, height: 28)
                let frame = ProjectTabPreviewLayout.frame(size: size, below: anchor, on: display)
                #expect(display.contains(frame))
                #expect(frame.maxY == anchor.minY - ProjectTabPreviewLayout.gap)
            }
        }
    }

    @Test func placementRemainsContainedAcrossScreenEdges() {
        for x in stride(from: -100, through: 1500, by: 40) {
            for y in stride(from: -100, through: 1000, by: 40) {
                let anchor = CGRect(x: x, y: y, width: 54, height: 28)
                let frame = ProjectTabPreviewLayout.frame(size: size, below: anchor, on: screen)
                #expect(screen.contains(frame))
                let roomBelow = anchor.minY - ProjectTabPreviewLayout.gap - screen.minY
                let roomAbove = screen.maxY - anchor.maxY - ProjectTabPreviewLayout.gap
                if screen.contains(anchor), max(roomBelow, roomAbove) >= size.height {
                    #expect(!frame.intersects(anchor))
                }
            }
        }
    }

    @Test func invalidGeometryIsRejected() {
        let anchor = CGRect(x: 100, y: 100, width: 54, height: 28)
        for value: CGFloat in [.nan, .infinity, -.infinity, 0, -10] {
            #expect(ProjectTabPreviewLayout.frame(
                size: CGSize(width: value, height: 196), below: anchor, on: screen) == .zero)
            #expect(ProjectTabPreviewLayout.frame(
                size: size, below: anchor,
                on: CGRect(x: 0, y: 0, width: 1440, height: value)) == .zero)
        }
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            #expect(ProjectTabPreviewLayout.frame(
                size: size, below: CGRect(x: value, y: 100, width: 54, height: 28), on: screen) == .zero)
        }
    }
}
