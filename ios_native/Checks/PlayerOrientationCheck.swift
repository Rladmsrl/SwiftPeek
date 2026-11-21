import Foundation

@main
enum PlayerOrientationCheck {
    static func main() {
        var checks = 0
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // 1. Issue #1 core repro: outer screen portrait -> fullscreen (.landscape) ->
        //    unfold hinge opens -> releases override with `.all` BEFORE inner display,
        //    and subsequent exit fullscreen on inner display issues NO geometry request.
        do {
            var state = PlayerOrientationState()
            let initialHeal = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            verify(initialHeal?.mask == .all && initialHeal?.kind == .releaseOverride,
                   "First idle closed hinge observation must heal any stale persisted scene override")
            verify(state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0) == nil,
                   "Subsequent closed hinge baseline updates must not emit duplicate requests")

            let enter = state.requestLandscapeFullscreen(current: .portrait)
            verify(enter?.mask == .landscape && enter?.kind == .enterLandscape,
                   "Outer portrait fullscreen must request landscape")
            verify(state.hasProgrammaticOverride && state.orientationBeforeFullscreen == .portrait,
                   "Outer portrait fullscreen must record override and entry orientation")

            // Minor hinge movement (< 20 deg) must not cancel outer fullscreen.
            verify(state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.25) == nil,
                   "Small hinge jitter must not release outer fullscreen")
            verify(state.hasProgrammaticOverride, "Override remains active below opening threshold")

            // Opening past 20 deg while still on outer screen must release to `.all`.
            let release = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.40)
            verify(release?.mask == .all && release?.kind == .releaseOverride,
                   "Unfolding past threshold must immediately release override to .all on outer screen")
            verify(!state.hasProgrammaticOverride && state.orientationBeforeFullscreen == nil,
                   "Release must clear override and saved outer orientation")

            // Reaching partiallyOpen / fullyOpen must not send a duplicate request on inner screen.
            verify(state.updateHinge(isAvailable: true, isClosed: false, isOpen: true, angleRadians: 1.57) == nil,
                   "Already-released override must not send duplicate request on inner display")
            verify(state.updateHinge(isAvailable: true, isClosed: false, isOpen: true, angleRadians: 3.14) == nil,
                   "Fully open must not send duplicate request")

            // Exiting fullscreen on inner screen must not trigger Code 101 portrait request.
            verify(state.restoreOrientationBeforeFullscreen() == nil,
                   "Exiting fullscreen on inner screen must not call requestGeometryUpdate")

            // Re-entering fullscreen on inner screen must not call requestGeometryUpdate.
            verify(state.requestLandscapeFullscreen(current: .portrait) == nil,
                   "Entering fullscreen on inner screen must not call requestGeometryUpdate")
        }

        // 2. Direct jump from closed -> open (without intermediate opening angle):
        //    must still emit `.all` release once.
        do {
            var state = PlayerOrientationState()
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            _ = state.requestLandscapeFullscreen(current: .portrait)
            let release = state.updateHinge(isAvailable: true, isClosed: false, isOpen: true, angleRadians: 1.6)
            verify(release?.mask == .all && release?.kind == .releaseOverride,
                   "Direct jump to open must still emit .all release")
            verify(state.updateHinge(isAvailable: true, isClosed: false, isOpen: true, angleRadians: 3.14) == nil,
                   "Second open update must not re-emit release")
        }

        // 3. Outer screen exit fullscreen -> restores portrait AND keeps tracking override
        //    so a subsequent unfold STILL releases to `.all`.
        do {
            var state = PlayerOrientationState()
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            _ = state.requestLandscapeFullscreen(current: .portrait)
            let restore = state.restoreOrientationBeforeFullscreen()
            verify(restore?.mask == .portrait && restore?.kind == .restorePrevious,
                   "Outer exit fullscreen must restore portrait")
            verify(state.hasProgrammaticOverride,
                   "Portrait restore must remain tracked in case device is physically sideways before unfold")
            let release = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.45)
            verify(release?.mask == .all && release?.kind == .releaseOverride,
                   "Unfolding after outer portrait restore must release to .all")
        }

        // 4. Entering fullscreen while ALREADY in landscape must NOT request rotation or pin on exit.
        do {
            var state = PlayerOrientationState()
            verify(state.requestLandscapeFullscreen(current: .landscapeLeft) == nil,
                   "Landscape entry must not request rotation")
            verify(!state.hasProgrammaticOverride && state.orientationBeforeFullscreen == nil,
                   "Landscape entry must not store entry orientation or override")
            verify(state.restoreOrientationBeforeFullscreen() == nil,
                   "Exiting fullscreen after landscape entry must not pin landscape")
        }

        // 5. Repeated enter calls while already landscape must preserve original portrait entry.
        do {
            var state = PlayerOrientationState()
            let first = state.requestLandscapeFullscreen(current: .portrait)
            verify(first?.mask == .landscape, "First call rotates to landscape")
            verify(state.requestLandscapeFullscreen(current: .landscapeRight) == nil,
                   "Second call while already landscape is a no-op")
            let restore = state.restoreOrientationBeforeFullscreen()
            verify(restore?.mask == .portrait, "Exit still restores original portrait")
        }

        // 6. Denial (Code 101) on iPad / Split View during enter must clear state so exit does not fire.
        do {
            var state = PlayerOrientationState()
            let enter = state.requestLandscapeFullscreen(current: .portrait)!
            state.recordRequestFailure(for: enter, deniedByWindowingMode: true)
            verify(!state.hasProgrammaticOverride && state.orientationBeforeFullscreen == nil,
                   "Code 101 on enter must clear override and saved orientation")
            verify(state.restoreOrientationBeforeFullscreen() == nil,
                   "Exit after denied enter must not call requestGeometryUpdate")
        }

        // 7. Race recovery: if `.all` release hit Code 101 because display already switched,
        //    folding back to closed or compact mode must retry `.all` once.
        do {
            var state = PlayerOrientationState()
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            _ = state.requestLandscapeFullscreen(current: .portrait)
            let release = state.updateHinge(isAvailable: true, isClosed: false, isOpen: true, angleRadians: 3.14)!
            state.recordRequestFailure(for: release, deniedByWindowingMode: true)
            verify(state.needsReleaseWhenAllowed, "Denied release must schedule retry")

            let retry = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            verify(retry?.mask == .all && retry?.kind == .releaseOverride,
                   "Folding back to closed must retry .all release")
            verify(!state.needsReleaseWhenAllowed, "Retry clears pending release flag")
            verify(state.sceneReturnedToCompactMode() == nil,
                   "No duplicate retry after already retried")
        }

        // 8. Compact-mode fallback retry (e.g. non-hinge Split View recovery).
        do {
            var state = PlayerOrientationState()
            _ = state.requestLandscapeFullscreen(current: .portrait)
            let restore = state.restoreOrientationBeforeFullscreen()!
            state.recordRequestFailure(for: restore, deniedByWindowingMode: true)
            verify(state.needsReleaseWhenAllowed, "Denied restore must schedule compact-mode release")
            let retry = state.sceneReturnedToCompactMode()
            verify(retry?.mask == .all && retry?.kind == .releaseOverride,
                   "Returning to compact mode must emit .all release")
        }

        // 9. Stale error callback from an older generation must not corrupt newer state.
        do {
            var state = PlayerOrientationState()
            let oldEnter = state.requestLandscapeFullscreen(current: .portrait)!
            let restore = state.restoreOrientationBeforeFullscreen()!
            verify(restore.generation > oldEnter.generation, "Generation must advance")
            state.recordRequestFailure(for: oldEnter, deniedByWindowingMode: true)
            verify(state.hasProgrammaticOverride, "Stale failure must not clear newer override")
        }

        // 10. Hysteresis: closing back after partial opening (< 0.20 rad) restores closed posture.
        do {
            var state = PlayerOrientationState()
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0)
            _ = state.requestLandscapeFullscreen(current: .portrait)
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.40)
            verify(state.blocksProgrammaticOrientation, "0.40 rad enters opening posture")
            // Still inside hysteresis band (0.25 rad): stays opening
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.25)
            verify(state.blocksProgrammaticOrientation, "Inside hysteresis band keeps opening posture")
            // Below 0.20 rad: returns to closed
            _ = state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0.10)
            verify(!state.blocksProgrammaticOrientation, "Below closed threshold restores outer fullscreen support")
            let reenter = state.requestLandscapeFullscreen(current: .portrait)
            verify(reenter?.mask == .landscape, "Outer fullscreen works again after closing")
        }

        // 11. Active fullscreen before first closed hinge delivery must not be cancelled.
        do {
            var state = PlayerOrientationState()
            let enter = state.requestLandscapeFullscreen(current: .portrait)
            verify(enter?.mask == .landscape, "Enter before initial hinge callback succeeds")
            verify(state.updateHinge(isAvailable: true, isClosed: true, isOpen: false, angleRadians: 0) == nil,
                   "Initial closed hinge callback must not cancel active fullscreen")
            verify(state.hasProgrammaticOverride, "Active fullscreen override stays intact")
        }

        print("Player orientation: \(checks) assertions passed")
    }
}
