import AVFoundation
import CoreText
import SimpleLiveKit
import Observation

/// Settings can be edited in another tab while the player view is offscreen.
/// Observe them independently of SwiftUI's view update/lifecycle callbacks.
@MainActor
final class PiPDanmakuPreference {
    private var generation = 0
    func watch(_ settings: AppSettings, onChange: @escaping @MainActor () -> Void) {
        generation += 1
        observe(settings, generation: generation, onChange: onChange)
    }
    func stop() { generation += 1 }
    private func observe(_ settings: AppSettings, generation token: Int, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = settings.data.pictureInPictureDanmaku
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings, self.generation == token else { return }
                onChange()
                self.observe(settings, generation: token, onChange: onChange)
            }
        }
    }
}

/// Read from the playback session, including while SwiftUI is suspended in the background.
struct PiPDanmakuSnapshot {
    var messages: [LiveMessage] = []
    var settings = DanmakuSettings()
    var isVisible = false
    var isPaused = false
    var clearToken = 0
    var sourceID = ""
}

/// A small, bounded raster timeline. Text is rasterized once per message; each
/// video frame only repositions those images. Coordinates use a 480-point canvas.
final class PiPDanmakuTimeline {
    struct Item {
        let image: CGImage
        let size: CGSize
        let track: Int
        let start: TimeInterval
        let opacity: CGFloat
    }
    private(set) var items: [Item] = []
    private var available: [TimeInterval] = []
    private var consumed: UUID?
    private var sourceID: String?
    private var clearToken = 0
    private var settings = DanmakuSettings()
    private var size = CGSize.zero
    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0
    private var wasPaused = false

    func reset() {
        items.removeAll()
        available.removeAll()
        consumed = nil
        sourceID = nil
        lastTime = nil
        clock = 0
        wasPaused = false
    }

    func update(_ snapshot: PiPDanmakuSnapshot, size: CGSize, at time: TimeInterval) {
        if let lastTime, !wasPaused { clock += max(0, time - lastTime) }
        lastTime = time
        wasPaused = snapshot.isPaused
        let changedSource = sourceID != snapshot.sourceID
        let cleared = !changedSource && clearToken != snapshot.clearToken
        let changedLayout = self.size != size || settings != snapshot.settings
        sourceID = snapshot.sourceID
        clearToken = snapshot.clearToken
        settings = snapshot.settings
        self.size = size
        let lineHeight = max(1, settings.fontSize * 1.6)
        let count = min(16, max(1, Int(size.height * settings.areaRatio / lineHeight)))
        if changedSource || cleared || changedLayout || !snapshot.isVisible {
            items.removeAll()
            available = Array(repeating: 0, count: count)
            if changedSource || cleared { consumed = nil }
        }
        guard snapshot.isVisible else {
            consumed = snapshot.messages.last?.id
            return
        }
        let speed = max(1, settings.speed)
        items.removeAll { clock - $0.start > (size.width + $0.size.width) / speed }
        let pending: ArraySlice<LiveMessage>
        if let consumed, let index = snapshot.messages.lastIndex(where: { $0.id == consumed }) {
            pending = snapshot.messages[(index + 1)...]
        } else {
            pending = snapshot.messages.suffix(cleared ? 160 : 5)
        }
        for message in pending {
            guard items.count < 80, let track = available.firstIndex(where: { $0 <= clock }) else { break }
            let font = settings.font.makeFont(size: settings.fontSize)
            let color = CGColor(srgbRed: CGFloat(message.color.r) / 255,
                                green: CGFloat(message.color.g) / 255,
                                blue: CGFloat(message.color.b) / 255, alpha: 1)
            guard let raster = DanmakuTextRasterizer.render(text: message.message, font: font, color: color,
                                                          strokeWidth: settings.strokeWidth, scale: 2) else { continue }
            items.append(Item(image: raster.image, size: raster.size, track: track, start: clock, opacity: settings.opacity))
            available[track] = clock + (raster.size.width + settings.gap) / speed
        }
        consumed = snapshot.messages.last?.id
    }

    func origin(for item: Item) -> CGPoint {
        CGPoint(x: size.width - (clock - item.start) * max(1, settings.speed),
                y: size.height - CGFloat(item.track) * settings.fontSize * 1.6 - item.size.height)
    }
}

/// CPU composition into reusable, bounded 960-pixel surfaces. This remains usable
/// when iOS restricts application GPU access in the background. No video encoding.
final class PiPFrameCompositor {
    let timeline = PiPDanmakuTimeline()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?
    private var outputSize = CGSize.zero
    private var format: CMVideoFormatDescription?

    func reset() {
        timeline.reset()
        pool = nil
        format = nil
        outputSize = .zero
    }

    func compose(_ frame: CVPixelBuffer, snapshot: PiPDanmakuSnapshot, at time: TimeInterval,
                 presentationTimeStamp: CMTime? = nil) -> CMSampleBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 960 / max(width, height))
        let size = CGSize(width: max(2, floor(width * scale / 2) * 2),
                          height: max(2, floor(height * scale / 2) * 2))
        if size != outputSize {
            outputSize = size
            format = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pixel: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixel) == kCVReturnSuccess,
              let pixel else { return nil }
        let canvas = CGSize(width: 480, height: 480 * size.height / size.width)
        timeline.update(snapshot, size: canvas, at: time)
        guard PiPPixelTransfer.copy(frame, to: pixel), drawMessages(into: pixel, size: size, canvas: canvas) else { return nil }
        if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: presentationTimeStamp ?? CMTime(seconds: time, preferredTimescale: 60_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
                                               sampleTiming: &timing, sampleBufferOut: &sample)
        // A control timebase is used by PiP. Keep PTS in that same clock domain;
        // combining it with DisplayImmediately is explicitly discouraged by AVFoundation.
        return sample
    }

    private func drawMessages(into buffer: CVPixelBuffer, size: CGSize, canvas: CGSize) -> Bool {
        guard !timeline.items.isEmpty else { return true }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                     width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                     bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return false }
        bitmap.scaleBy(x: size.width / canvas.width, y: size.height / canvas.height)
        for item in timeline.items {
            let origin = timeline.origin(for: item)
            guard origin.x < canvas.width, origin.x + item.size.width > 0 else { continue }
            bitmap.setAlpha(item.opacity)
            bitmap.draw(item.image, in: CGRect(origin: origin, size: item.size))
        }
        return true
    }
}
