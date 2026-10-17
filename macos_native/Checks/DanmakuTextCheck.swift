import AppKit
import CoreText

/// Offscreen pixels only: no NSApplication, windows, networking or playback.
@main
struct DanmakuTextCheck {
    static func main() {
        let samples = ["我提一嘴，同类型的艾希是16年的游戏", "绿梦破碎了吗", "2倍乐出爱，4倍快乐", "jÅg é e\u{301} 中文"]
        let colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(srgbRed: 1, green: 105.0 / 255, blue: 180.0 / 255, alpha: 1)]
        var checked = 0
        let sizes: [CGFloat] = [12, 16, 24, 32]
        let configurations: [(DanmakuFont, CGFloat)] = DanmakuFont.allCases.flatMap { style in
            sizes.map { (style, $0) }
        }
        for (style, size) in configurations {
            let font = style.makeFont(size: size)
            for scale: CGFloat in [1, 2, 3] {
                for text in samples {
                    for color in colors {
                        guard let plain = DanmakuTextRasterizer.render(text: text, font: font, color: color, strokeWidth: 0, scale: scale),
                              let outlined = DanmakuTextRasterizer.render(text: text, font: font, color: color, strokeWidth: 1.6, scale: scale),
                              let plainData = plain.image.dataProvider?.data,
                              let outlinedData = outlined.image.dataProvider?.data,
                              let a = CFDataGetBytePtr(plainData), let b = CFDataGetBytePtr(outlinedData)
                        else { fatalError("Missing text raster") }
                        precondition(plain.image.width == outlined.image.width && plain.image.height == outlined.image.height)
                        var solidPixels = 0
                        for y in 0..<plain.image.height {
                            for x in 0..<plain.image.width {
                                let i = y * plain.image.bytesPerRow + x * 4
                                // A black outline behind the fill must not eat/darken its RGB coverage.
                                for channel in 0..<3 {
                                    precondition(abs(Int(a[i + channel]) - Int(b[i + channel])) <= 1,
                                                 "Outline damaged fill: \(text), \(size)pt @\(scale)x")
                                }
                                if a[i + 3] == 255 { solidPixels += 1 }
                                if x == 0 || y == 0 || x == plain.image.width - 1 || y == plain.image.height - 1 {
                                    precondition(b[i + 3] == 0, "Glyph/outline clipped at bitmap edge")
                                }
                            }
                        }
                        precondition(solidPixels > 0, "Text has no solid fill")
                        checked += 1
                    }
                }
            }
        }
        print("PASS: \(checked) offscreen samples preserve fill RGB and leave unclipped glyph margins")
    }
}
