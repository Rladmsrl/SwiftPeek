import CoreGraphics
import CoreText
import Foundation

/// Render each message once, then move its image with Core Animation. Core Text
/// uses explicit CGColor attributes; the outline is drawn BEFORE the solid fill.
/// Drawing both together lets a centered stroke darken the inside of thin glyphs.
enum DanmakuTextRasterizer {
    struct Raster {
        let image: CGImage
        let size: CGSize
        let scale: CGFloat
    }

    static func render(text: String, font: CTFont, color: CGColor,
                       strokeWidth: CGFloat, scale: CGFloat) -> Raster? {
        guard !text.isEmpty, scale.isFinite, scale > 0, strokeWidth.isFinite else { return nil }
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
              let space = CGColorSpace(name: CGColorSpace.sRGB),
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
            outlineAttributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
            let outline = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: outlineAttributes))
            context.textPosition = origin
            CTLineDraw(outline, context)
            context.restoreGState()
        }
        context.setTextDrawingMode(.fill)
        context.textPosition = origin
        CTLineDraw(fill, context)
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, size: CGSize(width: pixelWidth / scale, height: pixelHeight / scale), scale: scale)
    }
}
