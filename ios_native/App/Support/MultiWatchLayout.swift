import Foundation
import CoreGraphics

/// Pure geometry: no device names, screen-size caches, or player identities.
struct MultiWatchLayout: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case balanced = "等分", stage = "主次"
        var id: Self { self }
    }
    var tiles: [CGRect]
    var companion: CGRect = .zero

    init(size: CGSize, count: Int, selected: Int = 0, mode: Mode = .balanced,
         focused: Bool = false, divisions: [CGRect] = [], occlusions: [CGRect] = []) {
        let count = min(4, max(0, count))
        tiles = Array(repeating: .zero, count: count)
        guard count > 0 else { return }
        let selected = min(max(selected, 0), count - 1)
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        let fold = divisions.map { $0.intersection(bounds) }.first {
            !$0.isNull && !$0.isEmpty &&
            (($0.height >= bounds.height * 0.8 && $0.minX > 0 && $0.maxX < bounds.maxX) ||
             ($0.width >= bounds.width * 0.8 && $0.minY > 0 && $0.maxY < bounds.maxY))
        }
        let available = Self.avoiding(divisions.filter { $0.intersection(bounds) != fold }, in: bounds)
        let order = [selected] + (0..<count).filter { $0 != selected }
        if let fold {
            let book = fold.height > fold.width
            let first = book
                ? CGRect(x: available.minX, y: available.minY, width: max(0, fold.minX - available.minX), height: available.height)
                : CGRect(x: available.minX, y: available.minY, width: available.width, height: max(0, fold.minY - available.minY))
            let second = book
                ? CGRect(x: fold.maxX, y: available.minY, width: max(0, available.maxX - fold.maxX), height: available.height)
                : CGRect(x: available.minX, y: fold.maxY, width: available.width, height: max(0, available.maxY - fold.maxY))
            if focused || count == 1 {
                tiles[selected] = first
                companion = second
            } else if book {
                // Book: a complete room on each leaf; four rooms become two per leaf.
                let leftCount = (count + 1) / 2
                let frames = Self.grid(first, count: leftCount, columns: 1)
                    + Self.grid(second, count: count - leftCount, columns: 1)
                for (index, frame) in frames.enumerated() { tiles[index] = frame }
            } else {
                // Tabletop: the selected stream above the hinge, other streams below.
                tiles[selected] = first
                for (index, frame) in zip(order.dropFirst(), Self.grid(second, count: count - 1, columns: count - 1)) {
                    tiles[index] = frame
                }
            }
        } else if focused {
            tiles[selected] = available
        } else {
            var video = available
            let roomy = min(available.width, available.height) >= 550
            if roomy && available.width > available.height {
                let panel = min(280, available.width * 0.28)
                video.size.width = max(0, available.width - panel - 8)
                companion = CGRect(x: video.maxX + 8, y: available.minY, width: panel, height: available.height)
            } else if available.height > available.width * 1.1 {
                let rows: CGFloat = count <= 2 ? CGFloat(count) : (count == 3 || mode == .stage ? 1.5 : 1)
                let height = min(available.height * 0.70, available.width * 9 / 16 * rows + (count > 1 ? 88 : 44))
                video.size.height = height
                companion = CGRect(x: available.minX, y: video.maxY + 8, width: available.width,
                                   height: max(0, available.maxY - video.maxY - 8))
            }
            if count >= 3 && (mode == .stage || count == 3) {
                let sideways = video.width > video.height * 1.25
                let main: CGRect
                let rest: CGRect
                if sideways {
                    main = CGRect(x: video.minX, y: video.minY, width: max(0, video.width * 0.66 - 4), height: video.height)
                    rest = CGRect(x: main.maxX + 8, y: video.minY, width: max(0, video.maxX - main.maxX - 8), height: video.height)
                } else {
                    main = CGRect(x: video.minX, y: video.minY, width: video.width, height: max(0, video.height * 0.62 - 4))
                    rest = CGRect(x: video.minX, y: main.maxY + 8, width: video.width, height: max(0, video.maxY - main.maxY - 8))
                }
                tiles[selected] = main
                for (index, frame) in zip(order.dropFirst(), Self.grid(rest, count: count - 1, columns: sideways ? 1 : count - 1)) {
                    tiles[index] = frame
                }
            } else {
                let columns = count <= 2 ? (video.width > video.height * 1.15 ? count : 1) : 2
                tiles = Self.grid(video, count: count, columns: max(1, columns))
            }
        }
        tiles = tiles.map { Self.avoiding(occlusions + divisions, in: $0) }
        companion = Self.avoiding(occlusions + divisions, in: companion)
    }

    private static func grid(_ rect: CGRect, count: Int, columns: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = max(1, columns)
        let rows = (count + columns - 1) / columns
        let gap = min(8, rect.width / CGFloat(columns), rect.height / CGFloat(rows))
        let width = max(0, (rect.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let height = max(0, (rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        return (0..<count).map { index in
            CGRect(x: rect.minX + CGFloat(index % columns) * (width + gap),
                   y: rect.minY + CGFloat(index / columns) * (height + gap), width: width, height: height)
        }
    }

    private static func avoiding(_ obstacles: [CGRect], in rect: CGRect) -> CGRect {
        obstacles.reduce(rect) { available, obstacle in
            let overlap = available.intersection(obstacle)
            guard !overlap.isNull, !overlap.isEmpty else { return available }
            let candidates = [
                CGRect(x: available.minX, y: available.minY, width: max(0, overlap.minX - available.minX), height: available.height),
                CGRect(x: overlap.maxX, y: available.minY, width: max(0, available.maxX - overlap.maxX), height: available.height),
                CGRect(x: available.minX, y: available.minY, width: available.width, height: max(0, overlap.minY - available.minY)),
                CGRect(x: available.minX, y: overlap.maxY, width: available.width, height: max(0, available.maxY - overlap.maxY))
            ]
            return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? available
        }
    }
}
