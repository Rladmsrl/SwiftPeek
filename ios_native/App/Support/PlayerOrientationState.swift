import Foundation

/// Pure state machine coordinating programmatic scene orientation requests across
/// foldable hinge transitions and multitasking windowing modes.
///
/// Kept independent of UIKit so fold/unfold and denial-recovery sequences can be
/// verified offline without booting a simulator.
struct PlayerOrientationState: Equatable {
    enum Direction: Equatable {
        case unknown
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight

        var isLandscape: Bool {
            self == .landscapeLeft || self == .landscapeRight
        }
    }

    enum TargetMask: Equatable {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight
        case landscape
        case all
    }

    enum RequestKind: Equatable {
        case enterLandscape
        case restorePrevious
        case releaseOverride
        case explicit
    }

    struct Request: Equatable {
        let mask: TargetMask
        let kind: RequestKind
        let generation: UInt64
    }

    enum HingePosture: Equatable {
        case unavailable
        case closed
        case opening
        case open
    }

    /// Angle threshold (radians, ~20 deg) at which an opening fold releases any
    /// active programmatic orientation override while the scene is still on the
    /// outer display where `requestGeometryUpdate` is permitted.
    static let openingAngleThreshold: Double = 0.35
    /// Hysteresis threshold (~11.5 deg) to treat a closing hinge as closed again.
    static let closedAngleThreshold: Double = 0.20

    private(set) var orientationBeforeFullscreen: Direction?
    private(set) var hasProgrammaticOverride = false
    private(set) var needsReleaseWhenAllowed = false
    private(set) var hingePosture: HingePosture = .unavailable
    private(set) var generation: UInt64 = 0
    private var didVerifyCleanClosedSession = false

    /// True once the foldable hinge is opening or open (inner display), where iOS
    /// rejects programmatic orientation changes with
    /// `UISceneErrorCodeGeometryRequestDenied` (101).
    var blocksProgrammaticOrientation: Bool {
        hingePosture == .opening || hingePosture == .open
    }

    mutating func requestLandscapeFullscreen(current: Direction) -> Request? {
        guard !blocksProgrammaticOrientation else { return nil }
        guard !current.isLandscape else { return nil }

        if orientationBeforeFullscreen == nil, current != .unknown {
            orientationBeforeFullscreen = current
        }
        hasProgrammaticOverride = true
        needsReleaseWhenAllowed = false
        return nextRequest(mask: .landscape, kind: .enterLandscape)
    }

    mutating func restoreOrientationBeforeFullscreen() -> Request? {
        guard let previous = orientationBeforeFullscreen else { return nil }
        orientationBeforeFullscreen = nil

        guard !blocksProgrammaticOrientation else {
            if hasProgrammaticOverride {
                needsReleaseWhenAllowed = true
            }
            return nil
        }

        let mask: TargetMask
        switch previous {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        case .unknown: return nil
        }
        // Restoring a specific direction can itself establish a scene preference
        // (for instance when the device was rotated sideways before exiting fullscreen).
        // Keep tracking the override so a subsequent unfold releases it back to `.all`.
        hasProgrammaticOverride = true
        needsReleaseWhenAllowed = false
        return nextRequest(mask: mask, kind: .restorePrevious)
    }

    mutating func requestExplicitOrientation(_ mask: TargetMask) -> Request? {
        guard !blocksProgrammaticOrientation else { return nil }
        if mask == .all {
            orientationBeforeFullscreen = nil
            hasProgrammaticOverride = false
            needsReleaseWhenAllowed = false
            return nextRequest(mask: .all, kind: .releaseOverride)
        }
        hasProgrammaticOverride = true
        needsReleaseWhenAllowed = false
        return nextRequest(mask: mask, kind: .explicit)
    }

    /// Update hinge state from `UIHingeInteraction`.
    mutating func updateHinge(isAvailable: Bool, isClosed: Bool, isOpen: Bool, angleRadians: Double) -> Request? {
        let nextPosture: HingePosture
        if !isAvailable {
            nextPosture = .unavailable
        } else if isOpen {
            nextPosture = .open
        } else if isClosed {
            if angleRadians >= Self.openingAngleThreshold {
                nextPosture = .opening
            } else if angleRadians < Self.closedAngleThreshold || hingePosture == .unavailable || hingePosture == .open {
                nextPosture = .closed
            } else {
                // Inside hysteresis band (0.20..<0.35 rad): preserve closed vs opening.
                nextPosture = hingePosture
            }
        } else {
            // Unknown status: keep current posture and avoid spurious requests.
            return nil
        }

        hingePosture = nextPosture

        switch nextPosture {
        case .opening, .open:
            // Drop saved outer entry direction: exiting fullscreen on the inner display
            // must never submit a doomed programmatic rotation back to portrait.
            orientationBeforeFullscreen = nil
            guard hasProgrammaticOverride else { return nil }
            hasProgrammaticOverride = false
            needsReleaseWhenAllowed = false
            return nextRequest(mask: .all, kind: .releaseOverride)

        case .closed:
            if needsReleaseWhenAllowed {
                needsReleaseWhenAllowed = false
                hasProgrammaticOverride = false
                orientationBeforeFullscreen = nil
                didVerifyCleanClosedSession = true
                return nextRequest(mask: .all, kind: .releaseOverride)
            }
            // SpringBoard can persist a prior scene's programmatic orientation override
            // across relaunches (for example after force-quitting in fullscreen or updating
            // from an older build). Releasing to `.all` once on an idle closed outer screen
            // heals stale overrides while preserving the device's physical orientation.
            if !didVerifyCleanClosedSession {
                didVerifyCleanClosedSession = true
                if !hasProgrammaticOverride && orientationBeforeFullscreen == nil {
                    return nextRequest(mask: .all, kind: .releaseOverride)
                }
            }
            return nil

        case .unavailable:
            return nil
        }
    }

    /// Fallback when a scene returns to compact width after an earlier release was
    /// denied in a non-rotatable windowing mode.
    mutating func sceneReturnedToCompactMode() -> Request? {
        guard needsReleaseWhenAllowed else { return nil }
        needsReleaseWhenAllowed = false
        hasProgrammaticOverride = false
        orientationBeforeFullscreen = nil
        return nextRequest(mask: .all, kind: .releaseOverride)
    }

    mutating func recordRequestFailure(for request: Request, deniedByWindowingMode: Bool) {
        guard deniedByWindowingMode, request.generation == generation else { return }
        switch request.kind {
        case .enterLandscape, .explicit:
            orientationBeforeFullscreen = nil
            hasProgrammaticOverride = false
        case .restorePrevious, .releaseOverride:
            needsReleaseWhenAllowed = true
        }
    }

    private mutating func nextRequest(mask: TargetMask, kind: RequestKind) -> Request {
        generation &+= 1
        return Request(mask: mask, kind: kind, generation: generation)
    }
}
