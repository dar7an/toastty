import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct TerminalPaneLayoutMenuTests {
    @Test func paletteButtonsTargetClickedPaneAndReflectZoom() throws {
        guard #available(macOS 14.0, *) else { return }
        // Menu construction should not need live PTYs or an application/window
        // lifecycle. Runtime pane routing is also exercised in desktop checks.
        let clickedPane = PaneActionTarget()

        let menu = NSMenu()
        TerminalPaneLayoutMenu.append(to: menu, target: clickedPane, hasSplits: true, isZoomed: false)
        let rows = menu.items.compactMap { $0.view as? PaneLayoutPaletteRowView }
        try #require(rows.count == 4)
        let buttons = rows.map { $0.arrangedSubviews.compactMap { $0 as? PaneLayoutMenuButton } }
        #expect(buttons[0].map { $0.menuAction.title } == ["Split Left", "Split Right", "Split Up", "Split Down"])
        #expect(buttons[1].map { $0.menuAction.title } == ["Zoom Split", "Equalize Splits"])
        #expect(buttons[2].map { $0.menuAction.title } == ["Move Left", "Move Right", "Move Up", "Move Down"])
        #expect(buttons[3].map { $0.menuAction.title } == ["Close Split"])
        for row in rows {
            row.layoutSubtreeIfNeeded()
            #expect(row.frame.width <= 260)
            #expect(row.frame.height >= 48)
        }
        for button in buttons.flatMap({ $0 }) {
            let item = button.menuAction
            #expect(item.target === clickedPane)
            #expect(item.image != nil)
            #expect(button.toolTip == item.title)
            #expect(button.frame.width == 48)
            #expect(button.frame.height == 40)
            button.performClick(nil)
        }
        #expect(clickedPane.actions == ["left", "right", "up", "down", "zoom", "equalize",
                                      "move-left", "move-right", "move-up", "move-down",
                                      "close"])

        let zoomedMenu = NSMenu()
        TerminalPaneLayoutMenu.append(to: zoomedMenu, target: clickedPane, hasSplits: true, isZoomed: true)
        let zoomedRows = zoomedMenu.items.compactMap { $0.view as? PaneLayoutPaletteRowView }
        try #require(zoomedRows.count == 4)
        #expect((zoomedRows[1].arrangedSubviews.first as? PaneLayoutMenuButton)?.menuAction.title == "Show All Splits")

        let singleMenu = NSMenu()
        TerminalPaneLayoutMenu.append(to: singleMenu, target: clickedPane, hasSplits: false, isZoomed: false)
        let singleRows = singleMenu.items.compactMap { $0.view as? PaneLayoutPaletteRowView }
        try #require(singleRows.count == 1)
        #expect(!singleRows[0].arrangedSubviews.compactMap({ $0 as? PaneLayoutMenuButton }).contains {
            $0.menuAction.title == "Close Split"
        })
    }
}

private final class PaneActionTarget: NSObject {
    var actions: [String] = []
    @objc func splitLeft(_ sender: Any?) { actions.append("left") }
    @objc func splitRight(_ sender: Any?) { actions.append("right") }
    @objc func splitUp(_ sender: Any?) { actions.append("up") }
    @objc func splitDown(_ sender: Any?) { actions.append("down") }
    @objc func zoomPaneFromMenu(_ sender: Any?) { actions.append("zoom") }
    @objc func equalizePanesFromMenu(_ sender: Any?) { actions.append("equalize") }
    @objc func moveSplitLeftFromMenu(_ sender: Any?) { actions.append("move-left") }
    @objc func moveSplitRightFromMenu(_ sender: Any?) { actions.append("move-right") }
    @objc func moveSplitUpFromMenu(_ sender: Any?) { actions.append("move-up") }
    @objc func moveSplitDownFromMenu(_ sender: Any?) { actions.append("move-down") }
    @objc func closeSplitFromMenu(_ sender: Any?) { actions.append("close") }
}
