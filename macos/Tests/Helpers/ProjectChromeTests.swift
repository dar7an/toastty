import Foundation
import Testing
@testable import Ghostty

struct ProjectChromeTests {
    @Test func hairlineIsOnePhysicalPixel() {
        #expect(ProjectChrome.hairline(displayScale: 1) == 1)
        #expect(ProjectChrome.hairline(displayScale: 2) == 0.5)
        #expect(abs(ProjectChrome.hairline(displayScale: 3) - 1.0 / 3.0) < 0.0001)
    }

    @Test func hairlineClampsDegenerateScales() {
        #expect(ProjectChrome.hairline(displayScale: 0) == 1)
        #expect(ProjectChrome.hairline(displayScale: -2) == 1)
    }
}
