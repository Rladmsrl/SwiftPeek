import Foundation
import QuartzCore

/// Offscreen geometry only. No NSApplication, panel, window, network or video.
@main
struct FloatingVideoCheck {
    static func main() {
        let inline = CALayer()
        let floating = CALayer()
        let video = CALayer()
        let inlineBounds = CGRect(x: 0, y: 0, width: 1100, height: 700)
        for i in 0..<1000 {
            inline.addSublayer(video)
            VideoLayerLayout.resize(video, ownedBy: inline, bounds: inlineBounds)
            precondition(video.frame == inlineBounds)
            floating.addSublayer(video)
            let small = CGRect(x: 0, y: 0, width: 300 + i % 300, height: 180 + i % 200)
            VideoLayerLayout.resize(video, ownedBy: floating, bounds: small)
            VideoLayerLayout.resize(video, ownedBy: inline, bounds: inlineBounds)
            precondition(video.frame == small, "Old inline layout overwrote floating geometry")
            inline.addSublayer(video)
            VideoLayerLayout.resize(video, ownedBy: inline, bounds: inlineBounds)
            VideoLayerLayout.resize(video, ownedBy: floating, bounds: small)
            precondition(video.frame == inlineBounds, "Old floating layout overwrote inline geometry")
        }
        print("PASS: 1000 transfers/resizes preserve the current host's geometry")
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
                     CGSize(width: 1080, height: 1920), CGSize(width: 640, height: 480)] {
            let ratio = FloatingVideoGeometry.aspect(for: size)
            let result = FloatingVideoGeometry.initialSize(aspect: ratio, available: CGSize(width: 1440, height: 900))
            precondition(abs(result.width / result.height - size.width / size.height) < 0.00001)
            precondition(result.width <= 420 && result.height <= 540)
        }
        precondition(FloatingVideoGeometry.aspect(for: nil) == 16.0 / 9)
        precondition(FloatingVideoGeometry.aspect(for: .zero) == 16.0 / 9)
        print("PASS: landscape/portrait/Retina dimensions preserve aspect ratio in points")
        let original = CGRect(x: 100, y: 200, width: 400, height: 225)
        let minimum = CGSize(width: 240, height: 135)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for delta in [CGSize(width: 100, height: 0), CGSize(width: 0, height: -100),
                      CGSize(width: -2000, height: 2000), CGSize(width: 9000, height: -9000)] {
            let result = FloatingVideoGeometry.resizedFrame(initial: original, delta: delta, minSize: minimum, visible: screen)
            precondition(result.minX == original.minX && result.maxY == original.maxY)
            precondition(abs(result.width / result.height - 16.0 / 9) < 0.00001)
            precondition(result.width >= 240 && result.height >= 135)
            precondition(result.maxX <= screen.maxX && result.minY >= screen.minY)
        }
        print("PASS: corner resizing preserves aspect, top-left anchor, minimum size and screen bounds")
    }
}
