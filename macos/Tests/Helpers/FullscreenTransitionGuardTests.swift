import Testing
@testable import Ghostty

struct FullscreenTransitionGuardTests {
    /// A watchdog for a finished transition must not clear a later one.
    @Test func staleWatchDoesNotClearLaterTransition() {
        var transition = FullscreenTransitionGuard()
        let first = transition.begin()
        transition.end()
        _ = transition.begin()
        let outcome = transition.evaluateWatchdog(
            first,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: true
        )
        #expect(outcome == .ignore)
        #expect(transition.isInFlight)
    }

    /// end() invalidates the watchdog that begin() scheduled.
    @Test func endInvalidatesScheduledWatch() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.end()
        #expect(!transition.isInFlight)
        let next = transition.begin()
        #expect(next != id)
        let outcome = transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: false
        )
        #expect(outcome == .ignore)
        #expect(transition.isInFlight)
    }

    /// Time alone does not release a native transition that is still off the active Space.
    @Test func activeSpaceAnimationDoesNotReleaseGuard() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.noteNativeBegan()
        let outcome = transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: false
        )
        #expect(outcome == .keep)
        #expect(transition.isInFlight)
    }

    /// Still on the active Space means the animation has not left yet.
    @Test func nativeTransitionBeforeLeavingKeepsGuard() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.noteNativeBegan()
        let outcome = transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: false
        )
        #expect(outcome == .keep)
        #expect(transition.isInFlight)
    }

    /// Returning after leaving, and still in flight on the next check, reconciles a missed notification.
    @Test func returnToActiveSpaceReconcilesMissedCompletion() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.noteNativeBegan()
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.isInFlight)
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .reconcile)
        #expect(!transition.isInFlight)
    }

    /// A transition that never receives will-enter or will-exit is released only after the grace period.
    @Test func unstartedTransitionWaitsForGrace() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.isInFlight)
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: false
        ) == .failed)
        #expect(!transition.isInFlight)
    }

    @Test func failureReleasesGuard() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.noteNativeBegan()
        transition.fail()
        #expect(!transition.isInFlight)
        _ = transition.begin()
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: false,
            unstartedGraceElapsed: true,
            giveUpElapsed: false
        ) == .ignore)
        #expect(transition.isInFlight)
    }

    @Test func closedWindowReleasesGuard() {
        var transition = FullscreenTransitionGuard()
        let id = transition.begin()
        transition.noteNativeBegan()
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: true,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .failed)
        #expect(!transition.isInFlight)
    }

    /// A native completion notification only ends the transition that started it.
    @Test func nativeCompletionDoesNotClearALaterTransition() {
        var transition = FullscreenTransitionGuard()
        _ = transition.begin()
        transition.noteNativeBegan()
        transition.endNativeCompletion()
        #expect(!transition.isInFlight)
        _ = transition.begin()
        transition.endNativeCompletion()
        #expect(transition.isInFlight)
    }

    /// will-enter for the green button, before a guard exists, must not stick.
    @Test func nativeBeganWithoutTransitionDoesNotStick() {
        var transition = FullscreenTransitionGuard()
        transition.noteNativeBegan()
        let id = transition.begin()
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: false,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.evaluateWatchdog(
            id,
            isOnActiveSpace: true,
            windowIsGone: false,
            unstartedGraceElapsed: false,
            giveUpElapsed: false
        ) == .keep)
        #expect(transition.isInFlight)
    }
}
