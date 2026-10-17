import Foundation

/// Point-based window geometry. Pixel dimensions determine only the aspect ratio;
/// Retina scale must never be applied to the window's point coordinates.
enum FloatingVideoGeometry {
    static func aspect(for videoSize: CGSize?) -> CGFloat {
        guard let size = videoSize, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    static func initialSize(aspect: CGFloat, available: CGSize) -> CGSize {
        let width = min(420, available.width * 0.6, available.height * 0.6 * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// Bottom-right grip, preserving the opposite (top-left) corner and aspect.
    static func resizedFrame(initial: CGRect, delta: CGSize, minSize: CGSize, visible: CGRect?) -> CGRect {
        let aspect = aspect(for: initial.size)
        let horizontal = delta.width
        let vertical = -delta.height * aspect
        let change = abs(horizontal) >= abs(vertical) ? horizontal : vertical
        let maximum = visible.map { min(max(minSize.width, $0.maxX - initial.minX),
                                         max(minSize.height, initial.maxY - $0.minY) * aspect) } ?? 4096
        let width = min(maximum, max(minSize.width, minSize.height * aspect, initial.width + change))
        let height = width / aspect
        return CGRect(x: initial.minX, y: initial.maxY - height, width: width, height: height)
    }
}
