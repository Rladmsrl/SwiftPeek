import QuartzCore

enum VideoLayerLayout {
    /// Reparenting transfers geometry ownership. The old host may still receive
    /// layout callbacks, but it must never move/resize a layer in another window.
    static func resize(_ video: CALayer, ownedBy host: CALayer, bounds: CGRect) {
        guard video.superlayer === host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}
