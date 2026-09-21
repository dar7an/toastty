import AppKit
import Testing
@testable import Ghostty

struct ProjectTabStripTests {
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

    @Test func selectedTabReceivesNativeWidthEmphasis() {
        let widths = ProjectTabStripView.cellWidths(
            available: 800,
            count: 4,
            selectedIndex: 1)
        #expect(widths == [189, 229, 189, 189])
        #expect(widths.reduce(0, +) + ProjectTabStripView.railPadding <= 800)
    }

    @Test func tenTabsCompressAroundSelectedTab() {
        let widths = ProjectTabStripView.cellWidths(
            available: 700,
            count: 10,
            selectedIndex: 4)
        #expect(widths[4] == ProjectTabStripView.selectedPreferredWidth)
        #expect(widths.filter { $0 == 56 }.count == 9)
        #expect(widths.reduce(0, +) + ProjectTabStripView.railPadding <= 700)
    }

    @Test func manyTabsOverflowOnlyAfterCompactLayout() {
        let widths = ProjectTabStripView.cellWidths(
            available: 800,
            count: 20,
            selectedIndex: 7)
        #expect(widths[7] == ProjectTabStripView.minimumSelectedWidth)
        #expect(widths.filter { $0 == ProjectTabStripView.compactCellWidth }.count == 19)
        #expect(widths.reduce(0, +) + ProjectTabStripView.railPadding > 800)
    }

    @Test func degenerateInputsStayAtMinimum() {
        #expect(ProjectTabStripView.cellWidths(
            available: 800,
            count: 0,
            selectedIndex: nil).isEmpty)
        #expect(ProjectTabStripView.cellWidths(
            available: 0,
            count: 1,
            selectedIndex: 0) == [ProjectTabStripView.minimumSelectedWidth])
        #expect(ProjectTabStripView.cellWidths(
            available: -50,
            count: 2,
            selectedIndex: nil) == [
                ProjectTabStripView.compactCellWidth,
                ProjectTabStripView.compactCellWidth,
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
