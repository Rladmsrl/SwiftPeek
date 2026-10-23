import Foundation
import CoreGraphics

@main
enum PlaybackLayoutCheck {
    static func main() {
        var checks = 0
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func check(_ size: CGSize, fullscreen: Bool, divisions: [CGRect] = [], occlusions: [CGRect] = []) {
            let result = PlaybackLayout(size: size, fullscreen: fullscreen,
                                        divisions: divisions, occlusions: occlusions)
            let bounds = CGRect(origin: .zero, size: size)
            for pane in [result.video, result.companion] {
                verify(pane.width >= 0 && pane.height >= 0, "Negative pane")
                verify(pane.minX >= 0 && pane.minY >= 0 && pane.maxX <= bounds.maxX + 0.001 && pane.maxY <= bounds.maxY + 0.001, "Pane outside container")
                for obstacle in divisions + occlusions {
                    let overlap = pane.intersection(obstacle)
                    verify(overlap.isNull || overlap.isEmpty, "Content crosses reserved region")
                }
            }
            let overlap = result.video.intersection(result.companion)
            verify(overlap.isNull || overlap.isEmpty, "Video and companion overlap")
            if !fullscreen && size.width > 0 && size.height > 0 && divisions.isEmpty && occlusions.isEmpty {
                verify(result.video.height > 0 && result.companion.height > 0, "Missing pane while browsing")
            }
        }

        // Sweep container sizes, not a list of known device dimensions. These
        // include very narrow Split View, short landscape, and large text layouts.
        for width in stride(from: 240, through: 1400, by: 20) {
            for height in stride(from: 180, through: 1200, by: 30) {
                let size = CGSize(width: width, height: height)
                for fullscreen in [false, true] {
                    check(size, fullscreen: fullscreen)
                    let book = CGRect(x: size.width * 0.47, y: 0, width: 24, height: size.height)
                    let tabletop = CGRect(x: 0, y: size.height * 0.48, width: size.width, height: 24)
                    check(size, fullscreen: fullscreen, divisions: [book])
                    check(size, fullscreen: fullscreen, divisions: [tabletop])
                    check(size, fullscreen: fullscreen, divisions: [book], occlusions: [CGRect(x: 8, y: 6, width: 24, height: 24)])
                    check(size, fullscreen: fullscreen, occlusions: [CGRect(x: size.width - 36, y: 0, width: 36, height: 36)])
                    let edgeFold = CGRect(x: -10, y: 0, width: 20, height: size.height)
                    check(size, fullscreen: fullscreen, divisions: [edgeFold])
                    let edgeLayout = PlaybackLayout(size: size, fullscreen: fullscreen, divisions: [edgeFold])
                    verify(edgeLayout.video.width > 0 && edgeLayout.video.height > 0, "Edge fold must not remove video")
                }
            }
        }
        check(.zero, fullscreen: false)
        check(.zero, fullscreen: true)
        let portrait = PlaybackLayout(size: CGSize(width: 390, height: 700), fullscreen: false)
        verify(portrait.companion.minY == portrait.video.maxY, "Portrait must stack")
        let landscape = PlaybackLayout(size: CGSize(width: 800, height: 320), fullscreen: false)
        verify(landscape.companion.minX > landscape.video.maxX, "Landscape must preserve side panel")
        let shortWide = PlaybackLayout(size: CGSize(width: 594, height: 350), fullscreen: false)
        verify(shortWide.companion.minX > shortWide.video.maxX && shortWide.companion.height == 350,
               "A wide outer-display container must leave a useful companion panel")
        let full = PlaybackLayout(size: CGSize(width: 390, height: 700), fullscreen: true)
        verify(full.companion.isEmpty && full.video.height == 700, "Fullscreen must respect explicit intent")
        print("Playback layout: \(checks) assertions passed")
    }
}
