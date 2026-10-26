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

/// Text layout and rasterization are confined to the overlay worker.
final class PiPDanmakuRasterizer {
    let timeline = PiPDanmakuTimeline()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func render(_ snapshot: PiPDanmakuSnapshot, size: CGSize, at time: TimeInterval) -> CGImage? {
        let canvas = CGSize(width: 480, height: 480 * size.height / size.width)
        timeline.update(snapshot, size: canvas, at: time)
        guard !timeline.items.isEmpty,
              let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        bitmap.scaleBy(x: size.width / canvas.width, y: size.height / canvas.height)
        for item in timeline.items {
            let origin = timeline.origin(for: item)
            guard origin.x < canvas.width, origin.x + item.size.width > 0 else { continue }
            bitmap.setAlpha(item.opacity)
            bitmap.draw(item.image, in: CGRect(origin: origin, size: item.size))
        }
        return bitmap.makeImage()
    }
}

/// One in-flight text render, no backlog. A slow/dense overlay can reduce its own
/// refresh rate without holding up video acquisition, scaling or submission.
final class PiPAsyncDanmakuRenderer: @unchecked Sendable {
    private struct Key: Equatable {
        let size: CGSize
        let settings: DanmakuSettings
        let sourceID: String
        let clearToken: Int
        let visible: Bool
        let paused: Bool
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var revision = 0
    private var busy = false
    private var latestKey: Key?
    private var latestImage: CGImage?
    // Only accessed by queue.
    private let rasterizer = PiPDanmakuRasterizer()
    private var renderedGeneration = -1

    init(queue: DispatchQueue = DispatchQueue(label: "com.simplelive.pip.danmaku", qos: .utility)) {
        self.queue = queue
    }

    func reset() {
        lock.lock()
        generation += 1
        revision += 1
        latestKey = nil
        latestImage = nil
        lock.unlock()
    }

    func image(snapshot: PiPDanmakuSnapshot, size: CGSize, at time: TimeInterval) -> CGImage? {
        let key = Key(size: size, settings: snapshot.settings, sourceID: snapshot.sourceID,
                      clearToken: snapshot.clearToken, visible: snapshot.isVisible, paused: snapshot.isPaused)
        lock.lock()
        // Invalidate immediately, even if a previous render is still running.
        if latestKey != key { latestKey = key; latestImage = nil; revision += 1 }
        let result = snapshot.isVisible ? latestImage : nil
        let token = generation
        let requestRevision = revision
        let shouldRender = !busy
        if shouldRender { busy = true }
        lock.unlock()
        if shouldRender {
            queue.async { [weak self] in
                guard let self else { return }
                autoreleasepool {
                    if self.renderedGeneration != token {
                        self.rasterizer.timeline.reset()
                        self.renderedGeneration = token
                    }
                    let image = self.rasterizer.render(snapshot, size: size, at: time)
                    self.lock.lock()
                    if self.generation == token, self.revision == requestRevision { self.latestImage = image }
                    self.busy = false
                    self.lock.unlock()
                }
            }
        }
        return result
    }
}

/// CPU video composition into bounded surfaces, with one cached transparent
/// overlay blend per frame. No text layout or application GPU work is required.
final class PiPFrameCompositor {
    private let rasterizer = PiPDanmakuRasterizer()
    var timeline: PiPDanmakuTimeline { rasterizer.timeline }
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
        // Synchronous entry point for offscreen pixel checks. The real-time pump
        // supplies an independently rendered overlay through the overload below.
        let overlay = rasterizer.render(snapshot, size: Self.size(for: frame), at: time)
        return compose(frame, overlay: overlay, at: time, presentationTimeStamp: presentationTimeStamp)
    }

    static func size(for frame: CVPixelBuffer) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        let scale = min(1, 960 / max(width, height))
        return CGSize(width: max(2, floor(width * scale / 2) * 2),
                          height: max(2, floor(height * scale / 2) * 2))
    }

    func compose(_ frame: CVPixelBuffer, overlay: CGImage?, at time: TimeInterval,
                 presentationTimeStamp: CMTime? = nil) -> CMSampleBuffer? {
        let size = Self.size(for: frame)
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
        guard PiPPixelTransfer.copy(frame, to: pixel) else { return nil }
        // Failure to paint optional text must not drop a successfully copied video frame.
        if let overlay { draw(overlay, into: pixel, size: size) }
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

    private func draw(_ overlay: CGImage, into buffer: CVPixelBuffer, size: CGSize) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                     width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                     bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        bitmap.draw(overlay, in: CGRect(origin: .zero, size: size))
    }
}
