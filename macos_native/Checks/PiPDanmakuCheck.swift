import Darwin
import AVFoundation
import CoreImage
import SimpleLiveKit
import VideoToolbox

/// Synthetic video and offscreen pixels only: no windows, app launch or network.
@main
struct PiPDanmakuCheck {
    static func message(_ text: String) -> LiveMessage {
        LiveMessage(kind: .chat, userName: "fixture", message: text)
    }

    static func main() throws {
        setbuf(stdout, nil)
        let old = try JSONDecoder().decode(SettingsData.self, from: Data("{\"playerVolume\":0.4}".utf8))
        precondition(!old.pictureInPictureDanmaku && old.floatingWindowOnTop && old.playerVolume == 0.4 && old.danmakuFont == .system)
        var custom = old
        custom.pictureInPictureDanmaku = true
        custom.floatingWindowOnTop = false
        custom.danmakuFont = .serif
        custom.danmakuFontSize = 24
        custom.danmakuOpacity = 0.65
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(custom))
        precondition(restored == custom)
        let futureFont = try JSONDecoder().decode(SettingsData.self, from: Data("{\"danmakuFont\":\"unavailable\",\"playerVolume\":0.4}".utf8))
        precondition(futureFont.danmakuFont == .system && futureFont.playerVolume == 0.4)
        print("PASS: old settings preserve values and new preferences round-trip")

        let timeline = PiPDanmakuTimeline()
        let size = CGSize(width: 480, height: 270)
        var snapshot = PiPDanmakuSnapshot(messages: [message("小窗弹幕测试")], isVisible: true, sourceID: "a")
        timeline.update(snapshot, size: size, at: 0)
        precondition(timeline.items.count == 1)
        let start = timeline.origin(for: timeline.items[0])
        timeline.update(snapshot, size: size, at: 1)
        precondition(timeline.items.count == 1 && timeline.origin(for: timeline.items[0]).x < start.x)
        snapshot.isPaused = true
        timeline.update(snapshot, size: size, at: 1)
        let frozen = timeline.origin(for: timeline.items[0])
        timeline.update(snapshot, size: size, at: 100)
        precondition(timeline.origin(for: timeline.items[0]) == frozen)
        snapshot.isPaused = false
        timeline.update(snapshot, size: size, at: 100)
        timeline.update(snapshot, size: size, at: 100.5)
        precondition(timeline.origin(for: timeline.items[0]).x < frozen.x)
        snapshot.clearToken += 1
        snapshot.messages = []
        timeline.update(snapshot, size: size, at: 101)
        precondition(timeline.items.isEmpty)
        snapshot.messages = [message("拖动后的新弹幕")]
        timeline.update(snapshot, size: size, at: 101)
        precondition(timeline.items.count == 1)
        snapshot.isVisible = false
        timeline.update(snapshot, size: size, at: 102)
        precondition(timeline.items.isEmpty)
        snapshot.isVisible = true
        timeline.update(snapshot, size: size, at: 102)
        precondition(timeline.items.isEmpty, "Hidden messages must not replay when re-enabled")
        snapshot.sourceID = "b"
        snapshot.messages = [message("另一段录像")]
        timeline.update(snapshot, size: size, at: 103)
        precondition(timeline.items.count == 1)
        print("PASS: no duplicate emission, pause/resume, seek clearing, visibility and segment changes")

        for i in 0..<2000 {
            snapshot.messages = [message("\(i)")]
            timeline.update(snapshot, size: size, at: Double(i) * 0.05 + 104)
            precondition(timeline.items.count <= 80)
        }
        print("PASS: dense messages keep bounded raster storage")

        let host = DanmakuHostView()
        host.wantsLayer = true
        host.frame = CGRect(origin: .zero, size: size)
        host.apply(DanmakuSettings())
        host.emit(text: "字体与可见度", color: .white)
        precondition(host.layer?.sublayers?.isEmpty == false)
        var edited = DanmakuSettings()
        edited.opacity = 0.35
        host.apply(edited)
        precondition(host.layer?.sublayers?.allSatisfy { abs($0.opacity - 0.35) < 0.001 } == true)
        edited.font = .serif
        host.apply(edited)
        precondition((host.layer?.sublayers ?? []).isEmpty, "Font changes must discard old-width glyphs before reusing tracks")
        print("PASS: visibility changes update flying labels; font changes clear the old track geometry")

        let compositor = PiPFrameCompositor()
        let pixel = makePixel()
        let videoOnly = compositor.compose(pixel, snapshot: PiPDanmakuSnapshot(), at: 0)!
        var visible = PiPDanmakuSnapshot(messages: [message("画中画里的弹幕")], isVisible: true, sourceID: "pixels")
        _ = compositor.compose(pixel, snapshot: visible, at: 1)
        let withText = compositor.compose(pixel, snapshot: visible, at: 2)!
        let plain = pixels(CMSampleBufferGetImageBuffer(videoOnly)!)
        let painted = pixels(CMSampleBufferGetImageBuffer(withText)!)
        precondition(plain != painted, "Text must be present in the actual output video pixels")
        let rowBytes = CVPixelBufferGetBytesPerRow(CMSampleBufferGetImageBuffer(withText)!)
        precondition(plain.suffix(rowBytes * 100) == painted.suffix(rowBytes * 100), "Bottom of video must be preserved")
        visible.isVisible = false
        let hidden = compositor.compose(pixel, snapshot: visible, at: 3)!
        precondition(pixels(CMSampleBufferGetImageBuffer(hidden)!) == plain, "Turning off danmaku removes the actual pixels")
        print("PASS: composited video pixels contain text, preserve video and clear when disabled")

        // Sample timestamps must match the renderer clock, not the animation clock.
        let mediaSample = compositor.compose(pixel, snapshot: visible, at: 50_000,
                                             presentationTimeStamp: CMTime(seconds: 12, preferredTimescale: 600))!
        precondition(CMSampleBufferGetPresentationTimeStamp(mediaSample).seconds == 12)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(mediaSample, createIfNecessary: false) as? [[String: Any]]
        precondition(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool != true)
        print("PASS: media-clock timestamps do not conflict with DisplayImmediately")

        cadenceCheck()
        try decodeCheck(pixel)
        pumpCheck(pixel)
    }

    static func cadenceCheck() {
        for fps in [24, 25, 30, 50, 60] {
            var cadence = PiPVideoSamplingClock()
            let accepted = (0..<(fps * 4)).filter { index in
                cadence.accepts(Double(index) / Double(fps) + (index % 2 == 0 ? 0.000_000_01 : 0))
            }.count
            precondition(abs(accepted - min(30, fps) * 4) <= 1, "Input sampling must not halve 30fps video")
        }
        print("PASS: 24/25/30/50/60 fps inputs retain the expected sampling cadence")
    }

    final class PumpProbe: @unchecked Sendable {
        let lock = NSLock()
        let pixel: CVPixelBuffer // Immutable fixture, read by the worker only.
        var seeded = false
        var count = 0
        var ready = true
        var pts: [Double] = []
        var firstPixels: Data?
        var lastPixels: Data?
        init(pixel: CVPixelBuffer) { self.pixel = pixel }
        func receive(_ sample: CMSampleBuffer) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                let image = pixels(buffer)
                if firstPixels == nil { firstPixels = image }
                lastPixels = image
            }
        }
        func read<T>(_ body: (PumpProbe) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(self)
        }
    }

    static func pumpCheck(_ pixel: CVPixelBuffer) {
        let probe = PumpProbe(pixel: pixel)
        let pump = PiPFramePump(timebase: nil, isReady: { probe.read { $0.ready } },
                                enqueue: { probe.receive($0) }, flush: {})
        let snapshot = PiPDanmakuSnapshot(messages: [message("独立于主线程的平滑弹幕")], isVisible: true, sourceID: "pump")
        pump.start(generation: 1) { token in
            let seed = probe.read { value in
                if value.seeded { return false }
                value.seeded = true
                return true
            }
            if seed {
                pump.submit(.init(frame: probe.pixel, snapshot: snapshot, hostTime: CACurrentMediaTime(),
                                  mediaTime: CMTime(seconds: 10, preferredTimescale: 600), rate: 1), generation: token)
            }
            // Deliberately stop publishing inputs, like a UI thread occupied by a long task.
        }
        Thread.sleep(forTimeInterval: 0.8)
        let frames = probe.read { $0.count }
        precondition(frames >= 30, "Animation must continue at a useful cadence without UI callbacks")
        precondition(probe.read { $0.firstPixels != $0.lastPixels }, "Cached-input danmaku must keep moving")
        precondition(probe.read { $0.pts.allSatisfy { $0 >= 10 && $0 < 12 } }, "PTS must remain in media time")
        probe.read { $0.ready = false }
        Thread.sleep(forTimeInterval: 0.05) // Let one in-flight frame finish.
        let beforePressure = probe.read { $0.count }
        Thread.sleep(forTimeInterval: 0.12)
        precondition(probe.read { $0.count } == beforePressure, "Backpressure must stop enqueueing")
        pump.stop()
        let stopped = probe.read { $0.count }
        Thread.sleep(forTimeInterval: 0.1)
        precondition(probe.read { $0.count } == stopped, "stop must reject late frames")
        probe.read { $0.ready = true }
        pump.start(generation: 2) { _ in }
        let input = PiPFramePump.Input(frame: pixel, snapshot: snapshot, hostTime: CACurrentMediaTime(),
                                       mediaTime: CMTime(seconds: 20, preferredTimescale: 600), rate: 1)
        pump.submit(input, generation: 1)
        Thread.sleep(forTimeInterval: 0.1)
        precondition(probe.read { $0.count } == stopped, "A stale producer cannot feed a new PiP session")
        pump.submit(input, generation: 2)
        Thread.sleep(forTimeInterval: 0.15)
        pump.stop()
        precondition(probe.read { $0.count } > stopped, "A new PiP session must resume normally")
        print("PASS: worker animation (\(frames) frames/0.8s), backpressure, stop and stale-generation rejection")
    }

    static func makePixel() -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pixel) == kCVReturnSuccess)
        let result = pixel!
        CVPixelBufferLockBaseAddress(result, [])
        let pointer = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<360 {
            for x in 0..<640 {
                let index = y * stride + x * 4
                pointer[index] = 180
                pointer[index + 1] = 40
                pointer[index + 2] = 20
                pointer[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    static func pixels(_ pixel: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(pixel)!, count: CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
    }

    static func decodeCheck(_ pixel: CVPixelBuffer) throws {
        let source = PiPLiveFrameSource()
        source.setEnabled(true)
        var encoder: VTCompressionSession?
        precondition(VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder) == noErr)
        let session = encoder!
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        for i in 0..<60 {
            precondition(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
                presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                    precondition(status == noErr)
                    if let sample { source.append(sample) }
                } == noErr)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let frame = source.frame(at: CMTime(seconds: 1, preferredTimescale: 600))
        precondition(frame != nil, "Real H.264 decode must yield frames selected on the playback clock")
        precondition(CVPixelBufferGetWidth(frame!) == 480)
        precondition(source.frame(at: CMTime(seconds: -1, preferredTimescale: 600)) == nil, "Do not display future frames")
        source.setEnabled(false)
        precondition(source.frame(at: CMTime(seconds: 2, preferredTimescale: 600)) == nil)
        source.setEnabled(true)
        precondition(source.frame(at: .zero) == nil, "A new PiP session must not reuse old video")
        source.setEnabled(false)
        print("PASS: synthetic H.264 decode, reduced-size frames, playback-clock selection and teardown")
    }
}
