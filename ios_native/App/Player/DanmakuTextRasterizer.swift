import CoreGraphics
import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DanmakuFont: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif

    var id: Self { self }
    var label: String {
        switch self {
        case .system: "标准"
        case .rounded: "圆体"
        case .serif: "衬线"
        }
    }

    private struct FontKey: Hashable {
        let font: DanmakuFont
        let deciPoints: Int
    }

    private static let fontLock = NSLock()
    private static var fontCache: [FontKey: CTFont] = [:]

    func makeFont(size: CGFloat) -> CTFont {
        let key = FontKey(font: self, deciPoints: Int((size * 10).rounded()))
        Self.fontLock.lock()
        if let cached = Self.fontCache[key] {
            Self.fontLock.unlock()
            return cached
        }
        Self.fontLock.unlock()
        #if os(macOS)
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let design: NSFontDescriptor.SystemDesign = self == .rounded ? .rounded : self == .serif ? .serif : .default
        let descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        #else
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        let design: UIFontDescriptor.SystemDesign = self == .rounded ? .rounded : self == .serif ? .serif : .default
        let descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        let font = UIFont(descriptor: descriptor, size: size)
        #endif
        let ctFont = font as CTFont
        Self.fontLock.lock()
        if Self.fontCache.count > 64 { Self.fontCache.removeAll(keepingCapacity: true) }
        Self.fontCache[key] = ctFont
        Self.fontLock.unlock()
        return ctFont
    }
}

/// Render each message once, then move its image with Core Animation. Core Text
/// uses explicit CGColor attributes; the outline is drawn BEFORE the solid fill.
/// Drawing both together lets a centered stroke darken the inside of thin glyphs.
enum DanmakuTextRasterizer {
    struct Raster {
        let image: CGImage
        let size: CGSize
        let scale: CGFloat
    }

    private final class CachedRaster: NSObject {
        let raster: Raster
        init(_ raster: Raster) { self.raster = raster }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    private static let outlineColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
    private static let cache: NSCache<NSString, CachedRaster> = {
        let cache = NSCache<NSString, CachedRaster>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 512
        return cache
    }()

    private static func cacheKey(text: String, font: CTFont, color: CGColor,
                                 strokeWidth: CGFloat, scale: CGFloat) -> NSString {
        let fontName = CTFontCopyPostScriptName(font) as String
        let fontSize = Int((CTFontGetSize(font) * 100).rounded())
        let stroke = Int((strokeWidth * 100).rounded())
        let scaleInt = Int((scale * 100).rounded())
        let spaceName = (color.colorSpace?.name as String?) ?? ""
        let components = (color.components ?? []).map { String(Int(($0 * 1000).rounded())) }.joined(separator: ",")
        return "\(fontName)|\(fontSize)|\(stroke)|\(scaleInt)|\(spaceName)|\(components)|\(text)" as NSString
    }

    static func render(text: String, font: CTFont, color: CGColor,
                       strokeWidth: CGFloat, scale: CGFloat) -> Raster? {
        guard !text.isEmpty, scale.isFinite, scale > 0, strokeWidth.isFinite else { return nil }
        let key: NSString? = text.count <= 24
            ? cacheKey(text: text, font: font, color: color, strokeWidth: strokeWidth, scale: scale)
            : nil
        if let key, let hit = cache.object(forKey: key) {
            return hit.raster
        }
        let fillAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 0,
        ]
        let fill = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: fillAttributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(fill, &ascent, &descent, &leading))
        // Include ink overhangs as well as font metrics (CJK, italic, combining marks, emoji).
        let ink = CTLineGetBoundsWithOptions(fill, .useGlyphPathBounds)
        let left = min(0, ink.isNull ? 0 : ink.minX)
        let right = max(advance, ink.isNull ? 0 : ink.maxX)
        let bottom = min(-descent, ink.isNull ? 0 : ink.minY)
        let top = max(ascent + leading, ink.isNull ? 0 : ink.maxY)
        let padding = ceil(max(3, CTFontGetSize(font) * max(0, strokeWidth) / 200 + 1))
        let pixelWidth = ceil((right - left + padding * 2) * scale)
        let pixelHeight = ceil((top - bottom + padding * 2) * scale)
        // Bound allocation for pathological external input. Normal chat is far below this limit.
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 32768, pixelHeight <= 4096, pixelWidth * pixelHeight <= 8_388_608,
              let space = sRGB,
              let context = CGContext(data: nil, width: Int(pixelWidth), height: Int(pixelHeight),
                                      bitsPerComponent: 8, bytesPerRow: Int(pixelWidth) * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        context.textMatrix = .identity
        let origin = CGPoint(x: padding - left, y: padding - bottom)

        if strokeWidth > 0 {
            context.saveGState()
            var outlineAttributes = fillAttributes
            outlineAttributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
            outlineAttributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = outlineColor
            let outline = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: outlineAttributes))
            context.textPosition = origin
            CTLineDraw(outline, context)
            context.restoreGState()
        }
        context.setTextDrawingMode(.fill)
        context.textPosition = origin
        CTLineDraw(fill, context)
        guard let image = context.makeImage() else { return nil }
        let raster = Raster(image: image, size: CGSize(width: pixelWidth / scale, height: pixelHeight / scale), scale: scale)
        if let key {
            cache.setObject(CachedRaster(raster), forKey: key, cost: Int(pixelWidth * pixelHeight * 4))
        }
        return raster
    }
}
