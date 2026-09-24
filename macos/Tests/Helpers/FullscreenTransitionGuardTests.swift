import Testing
@testable import Ghostty

struct FullscreenTransitionGuardTests {
    /// A watchdog for a finished transition must not clear a later one.
    @Test func staleTimeoutDoesNotClearLaterTransition() {
        var transition = FullscreenTransitionGuard()
        let first = transition.begin()
        transition.end()
        _ = transition.begin()
        transition.expire(first)
        #expect(transition.isInFlight)
    }

    /// The watchdog for the current transition clears it.
    @Test func currentTimeoutClearsTransition() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        #expect(transition.isInFlight)
        transition.expire(id)
        #expect(!transition.isInFlight)
    }

    /// end() invalidates the watchdog that begin() scheduled.
    @Test func endInvalidatesScheduledTimeout() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.end()
        #expect(!transition.isInFlight)
        let next = transition.begin()
        #expect(next != id)
        transition.expire(id)
        #expect(transition.isInFlight)
    }
}
