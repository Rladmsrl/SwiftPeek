import Foundation
import CoreGraphics

@main enum MultiWatchLayoutCheck {
    static func main() {
        var assertions = 0
        func verify(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); assertions += 1
        }
        func check(size: CGSize, count: Int, mode: MultiWatchLayout.Mode, focused: Bool,
                   divisions: [CGRect] = [], occlusions: [CGRect] = []) {
            let layout = MultiWatchLayout(size: size, count: count, selected: count - 1, mode: mode,
                                          focused: focused, divisions: divisions, occlusions: occlusions)
            verify(layout.tiles.count == count, "Room count changed")
            let frames = layout.tiles + [layout.companion]
            for (index, frame) in frames.enumerated() {
                verify(frame.width >= 0 && frame.height >= 0, "Negative dimensions")
                verify(frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= size.width + 0.001 && frame.maxY <= size.height + 0.001, "Outside container: \(size), \(frame)")
                for obstacle in divisions + occlusions {
                    let overlap = frame.intersection(obstacle)
                    verify(overlap.isNull || overlap.isEmpty, "Crosses fold/camera")
                }
                for other in frames.dropFirst(index + 1) {
                    let overlap = frame.intersection(other)
                    verify(overlap.isNull || overlap.isEmpty, "Overlapping panes")
                }
            }
            if focused { verify(layout.tiles.filter { !$0.isEmpty }.count == 1, "Focus must expose exactly one player") }
            else { verify(layout.tiles.allSatisfy { !$0.isEmpty }, "Missing live tile") }
        }
        for width in stride(from: 280, through: 1100, by: 40) {
            for height in stride(from: 220, through: 1100, by: 40) {
                let size = CGSize(width: width, height: height)
                for count in 1...4 {
                    for mode in MultiWatchLayout.Mode.allCases {
                        for focused in [false, true] {
                            check(size: size, count: count, mode: mode, focused: focused)
                            check(size: size, count: count, mode: mode, focused: focused,
                                  divisions: [CGRect(x: size.width * 0.43, y: 0, width: 22, height: size.height)])
                            check(size: size, count: count, mode: mode, focused: focused,
                                  divisions: [CGRect(x: 0, y: size.height * 0.47, width: size.width, height: 22)],
                                  occlusions: [CGRect(x: size.width - 26, y: 0, width: 26, height: 26)])
                            check(size: size, count: count, mode: mode, focused: focused,
                                  divisions: [CGRect(x: -10, y: 0, width: 20, height: size.height)])
                        }
                    }
                }
            }
        }
        let phone = MultiWatchLayout(size: CGSize(width: 374, height: 650), count: 2)
        verify(phone.tiles[1].minY > phone.tiles[0].maxY, "Phone portrait must stack two streams")
        let landscape = MultiWatchLayout(size: CGSize(width: 700, height: 300), count: 2)
        verify(landscape.tiles[1].minX > landscape.tiles[0].maxX, "Phone landscape must place two streams side by side")
        let four = MultiWatchLayout(size: CGSize(width: 374, height: 650), count: 4)
        verify(four.tiles[0].minY == four.tiles[1].minY && four.tiles[2].minY > four.tiles[0].maxY, "Four-up must be a grid")
        let expanded = MultiWatchLayout(size: CGSize(width: 900, height: 600), count: 4)
        verify(expanded.companion.width >= 240, "Expanded Duo must offer a readable side panel")
        verify(MultiWatchRoomInput.roomID(" https://www.douyu.com/000123?from=share ") == "123", "Room URL normalization")
        verify(MultiWatchRoomInput.roomID("https://example.com/123") == nil, "Reject unrelated links")
        verify(MultiWatchRoomInput.roomID("主播123") == nil, "Search names are not room IDs")
        verify(MultiWatchRoomInput.roomID("000") == nil, "Reject empty canonical IDs")
        print("Multi-watch layout and input: \(assertions) assertions passed")
    }
}
