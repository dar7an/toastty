import AppKit
import Testing
@testable import Ghostty

struct ProjectTabStripTests {
    @MainActor
    @Test func hoverPreviewStaysOnScreenAtRailEdges() {
        let screen = NSRect(x: -1440, y: 20, width: 1440, height: 900)
        for x: CGFloat in [-1430, -750, -10] {
            let anchor = NSRect(x: x, y: 860, width: 54, height: 28)
            let frame = ProjectTabHoverPreview.frame(size: NSSize(width: 300, height: 240),
                                                    below: anchor, on: screen)
            #expect(screen.contains(frame))
            #expect(frame.maxY == anchor.minY - 8)
        }
    }

    @Test func tabWindowMorphCanReverseWithoutJumping() {
        var morph = ProjectTabDragMorph()
        morph.advance(by: 0.06, reduceMotion: false)
        #expect(morph.value > 0 && morph.value < 1)
        let position = morph.value
        let velocity = morph.velocity
        morph.target = 0
        #expect(morph.value == position)
        #expect(morph.velocity == velocity)
        for _ in 0..<60 { morph.advance(by: 1 / 60, reduceMotion: false) }
        #expect(morph.value == 0)
        #expect(morph.isSettled)
        morph.target = 1
        morph.advance(by: 0, reduceMotion: true)
        #expect(morph.value == 1)
        #expect(morph.isSettled)
    }

    @Test func singleTabFillsRail() {
        #expect(ProjectTabStripView.cellWidths(
            available: 800,
            count: 1,
            selectedIndex: 0) == [796])
    }

    @Test(arguments: [2, 4, 10, 20])
    func switchingTabsNeverChangesCellWidths(count: Int) {
        let baseline = ProjectTabStripView.cellWidths(available: 800, count: count, selectedIndex: nil)
        for selection in 0..<count {
            #expect(ProjectTabStripView.cellWidths(
                available: 800, count: count, selectedIndex: selection) == baseline)
        }
        #expect(Set(baseline).count == 1)
        #expect(baseline.allSatisfy { $0 >= ProjectTabStripView.minimumCellWidth })
    }

    @Test func tabsFillAvailableSpaceThenScrollWithReadableTitles() {
        let normal = ProjectTabStripView.cellWidths(available: 800, count: 4, selectedIndex: 1)
        #expect(normal == [199, 199, 199, 199])
        #expect(normal.reduce(0, +) + ProjectTabStripView.railPadding == 800)
        let crowded = ProjectTabStripView.cellWidths(available: 700, count: 10, selectedIndex: 4)
        #expect(crowded == Array(repeating: 120, count: 10))
        #expect(crowded.reduce(0, +) > 700)
    }

    @Test func degenerateInputsStayAtMinimum() {
        #expect(ProjectTabStripView.cellWidths(
            available: 800,
            count: 0,
            selectedIndex: nil).isEmpty)
        #expect(ProjectTabStripView.cellWidths(
            available: 0,
            count: 1,
            selectedIndex: 0) == [ProjectTabStripView.minimumCellWidth])
        #expect(ProjectTabStripView.cellWidths(
            available: -50,
            count: 2,
            selectedIndex: nil) == [
                ProjectTabStripView.minimumCellWidth,
                ProjectTabStripView.minimumCellWidth,
            ])
    }

    @Test func dropCompletesAfterLatePayloadLoad() async {
        // performDrop can arrive before begin's asynchronous publish; the
        // delegates then load the providers directly and commit on finish.
        let session = TerminalLayoutDragSession()
        let payload = TerminalLayoutDragPayload.surface(UUID())
        session.begin([payload.itemProvider()])
        var committed: TerminalLayoutDragPayload?
        let accepted = session.finishDrop([payload.itemProvider()]) { committed = $0 }
        #expect(accepted)
        for _ in 0..<5 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(committed == payload)
        // The session ended, so its pending publish cannot revive the drag.
        #expect(session.payload == nil)
    }

    @Test func dropWithoutProvidersIsRejected() {
        let session = TerminalLayoutDragSession()
        #expect(session.finishDrop([]) { _ in } == false)
    }
}
