import Foundation
import Testing
@testable import Ghostty

struct SidebarStateTests {
    @Test(arguments: [CGFloat(-20), 0, 900])
    func restoredWidthsAreClamped(_ width: CGFloat) throws {
        let data = Data("{\"isVisible\":false,\"expandedWidth\":\(width)}".utf8)
        let state = try JSONDecoder().decode(SidebarState.self, from: data)
        #expect(!state.isVisible)
        #expect(state.expandedWidth == min(TabSidebarModel.maxWidth, max(TabSidebarModel.minWidth, width)))
    }

    @Test(arguments: [CGFloat.nan, .infinity, -.infinity])
    func nonfiniteWidthsUseDefault(_ width: CGFloat) {
        let state = SidebarState(isVisible: true, expandedWidth: width)
        #expect(state.expandedWidth == TabSidebarModel.defaultWidth)
    }
}
