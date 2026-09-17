import AppKit
import Testing
@testable import Ghostty

struct ProjectTabStripTests {
    @Test func singleTabFillsRail() {
        // (800 - 6) / 1 floors to the full interior width.
        #expect(ProjectTabStripView.cellWidth(available: 800, count: 1) == 794)
    }

    @Test func fewTabsShareRailEqually() {
        // (800 - 6) / 4 = 198.5 floors to 198 per cell.
        let width = ProjectTabStripView.cellWidth(available: 800, count: 4)
        #expect(width == 198)
        // Cells plus rail padding fit without scrolling.
        #expect(width * 4 + ProjectTabStripView.capsulePadding <= 800)
    }

    @Test func manyTabsOverflowAtMinimumWidth() {
        // (800 - 6) / 20 = 39.7 would be unusable, so cells clamp to the
        // minimum and the rail scrolls instead.
        #expect(ProjectTabStripView.cellWidth(available: 800, count: 20) == 96)
        #expect(ProjectTabStripView.cellWidth(available: 800, count: 20) == ProjectTabStripView.minCellWidth)
    }

    @Test func fillOverflowBoundary() {
        // (390 - 6) / 4 is exactly the 96pt minimum: still filling.
        #expect(ProjectTabStripView.cellWidth(available: 390, count: 4) == 96)
        // One point narrower overflows, but the width never drops below min.
        #expect(ProjectTabStripView.cellWidth(available: 389, count: 4) == 96)
        #expect(ProjectTabStripView.cellWidth(available: 200, count: 4) == ProjectTabStripView.minCellWidth)
    }

    @Test func degenerateInputsStayAtMinimum() {
        #expect(ProjectTabStripView.cellWidth(available: 800, count: 0) == ProjectTabStripView.minCellWidth)
        #expect(ProjectTabStripView.cellWidth(available: 0, count: 4) == ProjectTabStripView.minCellWidth)
        #expect(ProjectTabStripView.cellWidth(available: -50, count: 2) == ProjectTabStripView.minCellWidth)
    }
}
