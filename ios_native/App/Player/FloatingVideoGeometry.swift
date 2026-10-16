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
}
