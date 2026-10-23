import Foundation
import CoreGraphics

/// Container coordinates, never screen dimensions or device orientation.
/// Kept independent of SwiftUI so resizing and fold avoidance can be checked offline.
struct PlaybackLayout: Equatable {
    let video: CGRect
    let companion: CGRect

    init(size: CGSize, fullscreen: Bool, divisions: [CGRect] = [], occlusions: [CGRect] = []) {
        let container = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        let fold = divisions.map({ $0.intersection(container) }).first(where: {
            guard !$0.isNull, !$0.isEmpty else { return false }
            if $0.height > $0.width {
                return $0.height >= container.height * 0.8 && $0.minX > 0 && $0.maxX < container.maxX
            }
            return $0.width >= container.width * 0.8 && $0.minY > 0 && $0.maxY < container.maxY
        })
        // A fold touching a Split View edge is an inset, not two usable panes.
        let bounds = fold == nil ? Self.avoiding(divisions, in: container) : container
        var primary: CGRect
        var secondary: CGRect

        // A division is active only while the display is partially folded.
        // Use its actual position, including margins, rather than assuming a center hinge.
        if let fold {
            if fold.height > fold.width {
                primary = CGRect(x: 0, y: 0, width: fold.minX, height: bounds.height)
                secondary = CGRect(x: fold.maxX, y: 0, width: max(0, bounds.width - fold.maxX), height: bounds.height)
            } else {
                primary = CGRect(x: 0, y: 0, width: bounds.width, height: fold.minY)
                secondary = CGRect(x: 0, y: fold.maxY, width: bounds.width, height: max(0, bounds.height - fold.maxY))
            }
        } else if fullscreen {
            primary = bounds
            secondary = .zero
        } else if bounds.width >= 320 + 240 + 1 && bounds.width > bounds.height * 1.15 {
            let panelWidth = min(380, max(240, bounds.width * 0.34))
            primary = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - panelWidth - 1, height: bounds.height)
            secondary = CGRect(x: primary.maxX + 1, y: bounds.minY, width: panelWidth, height: bounds.height)
        } else {
            let videoHeight = min(bounds.width / (16.0 / 9.0), bounds.height * 0.55)
            primary = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: videoHeight)
            secondary = CGRect(x: bounds.minX, y: primary.maxY, width: bounds.width, height: max(0, bounds.height - videoHeight))
        }

        video = Self.avoiding(occlusions, in: primary)
        companion = Self.avoiding(occlusions, in: secondary)
    }

    /// Cameras are small occlusions, not folds. Trim the least costly edge of
    /// each pane instead of splitting the entire layout around a camera.
    private static func avoiding(_ obstacles: [CGRect], in region: CGRect) -> CGRect {
        obstacles.reduce(region) { available, obstacle in
            let overlap = available.intersection(obstacle)
            guard !overlap.isNull, !overlap.isEmpty else { return available }
            let candidates = [
                CGRect(x: available.minX, y: available.minY, width: max(0, overlap.minX - available.minX), height: available.height),
                CGRect(x: overlap.maxX, y: available.minY, width: max(0, available.maxX - overlap.maxX), height: available.height),
                CGRect(x: available.minX, y: available.minY, width: available.width, height: max(0, overlap.minY - available.minY)),
                CGRect(x: available.minX, y: overlap.maxY, width: available.width, height: max(0, available.maxY - overlap.maxY))
            ]
            return candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) ?? available
        }
    }
}
