import Foundation
import Testing
@testable import Ghostty

struct SplitDividerSnapTests {
    @Test(arguments: [CGFloat(300), 900, 1800])
    func capturesHalvesAndThirdsWithinSixPoints(extent: CGFloat) {
        for target in SplitDividerSnap.ratios {
            let result = SplitDividerSnap.resolve(position: target * extent + 5, extent: extent,
                                                  previous: nil, enabled: true)
            #expect(result.ratio == target)
            #expect(result.target == target)
        }
    }

    @Test func retainsSnapUntilReleaseDistanceThenTracksPointer() {
        let held = SplitDividerSnap.resolve(position: 509, extent: 1000, previous: 0.5, enabled: true)
        #expect(held.ratio == 0.5)
        let released = SplitDividerSnap.resolve(position: 511, extent: 1000, previous: 0.5, enabled: true)
        #expect(released.target == nil)
        #expect(released.ratio == 0.511)
        let returning = SplitDividerSnap.resolve(position: 508, extent: 1000, previous: nil, enabled: true)
        #expect(returning.target == nil)
    }

    @Test func optionBypassesSnapAndPreservesMinimumSizes() {
        let free = SplitDividerSnap.resolve(position: 504, extent: 1000, previous: 0.5, enabled: false)
        #expect(free.target == nil)
        #expect(free.ratio == 0.504)
        #expect(SplitDividerSnap.resolve(position: -100, extent: 1000, previous: nil, enabled: true).ratio == 0.01)
        #expect(SplitDividerSnap.resolve(position: 1200, extent: 1000, previous: nil, enabled: true).ratio == 0.99)
    }

    @Test func tinyOrInvalidExtentsNeverProduceInvalidRatios() {
        let extents: [CGFloat] = [0, 10, .infinity, .nan]
        for extent in extents {
            let result = SplitDividerSnap.resolve(position: 20, extent: extent, previous: 1 / 3, enabled: true)
            #expect(result.ratio == 0.5)
            #expect(result.target == nil)
        }
    }
}
