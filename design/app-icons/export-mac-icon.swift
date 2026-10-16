import AppKit

// Platform packaging only: keep the selected artwork intact, resize into the
// macOS icon footprint, and apply the standard rounded outer silhouette.
let arguments = CommandLine.arguments
precondition(arguments.count == 3, "Usage: export-mac-icon.swift source.png output.iconset")
let sourceURL = URL(fileURLWithPath: arguments[1])
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let input = NSImage(contentsOf: sourceURL),
      let source = input.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Cannot load master") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { fatalError("Cannot create output") }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: frame, cornerWidth: 180, cornerHeight: 180, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(source, in: frame)
        let suffix = scale == 2 ? "@2x" : ""
        let output = folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        try data.write(to: output)
    }
}
