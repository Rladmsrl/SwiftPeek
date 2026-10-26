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
        try decodeCheck(pixel, reordered: false)
        try decodeCheck(pixel, reordered: true)
        pumpCheck(pixel)
        overlayCheck(pixel)
        videoPriorityCheck()
    }

    static func cadenceCheck() {
        for fps in [24, 25, 30, 50, 60, 120] {
            var cadence = PiPVideoSamplingClock()
            let accepted = (0..<(fps * 4)).filter { index in
                cadence.accepts(Double(index) / Double(fps) + (index % 2 == 0 ? 0.000_000_01 : 0))
            }.count
            precondition(abs(accepted - min(60, fps) * 4) <= 1, "PiP must preserve every source frame up to 60fps")
        }
        for fps in [24, 25, 30, 50, 60] {
            for rounded in [false, true] {
                var cadence = PiPVideoSamplingClock()
                let accepted = (0..<(fps * 4)).filter { index in
                    let milliseconds = Double(index) * 1000 / Double(fps)
                    return cadence.accepts((rounded ? milliseconds.rounded() : floor(milliseconds)) / 1000)
                }.count
                precondition(accepted == fps * 4, "Millisecond FLV timestamps must retain all \(fps)fps frames: \(accepted)")
            }
        }
        print("PASS: integer-millisecond FLV timestamps retain every 24/25/30/50/60fps frame")
        for fps in [24, 25, 30, 50, 60] {
            for offset in [0.0, 0.015, 30.003] {
                var cadence = PiPVideoSamplingClock()
                // Reference frame first, then its earlier B frames (I P B B B).
                let order = stride(from: 0, to: fps * 4, by: 4).flatMap { start in
                    [start + 3, start, start + 1, start + 2].filter { $0 < fps * 4 }
                }
                let times = order.map { floor((Double($0) / Double(fps) + offset) * 1000) / 1000 }
                precondition(times.allSatisfy { cadence.accepts($0) }, "Reordered B frames must survive sampling at \(fps)fps")
                precondition(!cadence.accepts(times.last!), "A repeated source timestamp must not be counted as a new frame")
            }
        }
        print("PASS: reordered I/P/B timestamps retain full video cadence, including millisecond quantization and nonzero origins")
        print("PASS: 24/25/30/50/60 fps inputs retain their full cadence; 120 fps is bounded to 60")
    }

    final class PumpProbe: @unchecked Sendable {
        let lock = NSLock()
        let pixel: CVPixelBuffer // Immutable fixture, read by the worker only.
        let fixtures: [CVPixelBuffer]
        var seeded = false
        var count = 0
        var ready = true
        var pts: [Double] = []
        var firstPixels: Data?
        var lastPixels: Data?
        var videoMarkers: [UInt8] = []
        var requested = 0
        init(pixel: CVPixelBuffer, fixtures: [CVPixelBuffer] = []) {
            self.pixel = pixel
            self.fixtures = fixtures
        }
        func receive(_ sample: CMSampleBuffer) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                let image = pixels(buffer)
                if firstPixels == nil { firstPixels = image }
                lastPixels = image
                videoMarkers.append(image[0])
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

    final class EncodedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var sample: CMSampleBuffer?
        private var previousPTS = CMTime.invalid
        private var reordered = false
        func keepFirst(_ sample: CMSampleBuffer) {
            lock.lock(); defer { lock.unlock() }
            if self.sample == nil { self.sample = sample }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if previousPTS.isValid, pts < previousPTS { reordered = true }
            previousPTS = pts
        }
        var first: CMSampleBuffer? {
            lock.lock(); defer { lock.unlock() }
            return sample
        }
        var hasReorderedFrames: Bool {
            lock.lock(); defer { lock.unlock() }
            return reordered
        }
    }

    static func decodeCheck(_ pixel: CVPixelBuffer, reordered: Bool) throws {
        let source = PiPLiveFrameSource()
        let encoded = EncodedProbe()
        source.setEnabled(true)
        var encoder: VTCompressionSession?
        precondition(VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder) == noErr)
        let session = encoder!
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: reordered ? kCFBooleanTrue : kCFBooleanFalse)
        if reordered {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        for i in 0..<240 {
            precondition(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
                presentationTimeStamp: CMTime(value: Int64(i), timescale: 60), duration: CMTime(value: 1, timescale: 60),
                frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                    precondition(status == noErr)
                    if let sample { encoded.keepFirst(sample); source.append(sample) }
                } == noErr)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if reordered {
            precondition(encoded.hasReorderedFrames, "The B-frame fixture must actually produce non-monotonic presentation timestamps")
        }
        var previous: CVPixelBuffer?
        for i in 0..<240 {
            let decoded = source.frame(at: CMTime(value: Int64(i), timescale: 60))
            precondition(decoded != nil && decoded !== previous,
                         "Four seconds of 60fps video must retain 240 distinct frames, including the oldest unplayed frame")
            precondition(CVPixelBufferGetDataSize(decoded!) * 244 <= 96 * 1024 * 1024,
                         "The complete 60fps lookahead must fit the existing memory budget")
            previous = decoded
        }
        let frame = source.frame(at: CMTime(value: 239, timescale: 60))
        precondition(frame != nil, "Real H.264 decode must yield frames selected on the playback clock")
        precondition(CVPixelBufferGetWidth(frame!) <= 480)
        precondition(source.frame(at: CMTime(seconds: -1, preferredTimescale: 600)) == nil, "Do not display future frames")
        let oldRevision = source.revision
        source.reset(streamGeneration: 7)
        precondition(source.revision != oldRevision && source.frame(at: .zero) == nil,
                     "A restart must clear both decoder state and retained frames")
        source.append(encoded.first!, generation: 0)
        precondition(source.frame(at: .zero) == nil, "Late compressed input from an old stream must be rejected")
        source.append(encoded.first!, generation: 7)
        precondition(source.frame(at: .zero) != nil, "The same codec/PTS must decode normally in a new stream generation")
        source.setEnabled(false)
        precondition(source.frame(at: CMTime(seconds: 2, preferredTimescale: 600)) == nil)
        source.setEnabled(true)
        precondition(source.frame(at: .zero) == nil, "A new PiP session must not reuse old video")
        source.setEnabled(false)
        print("PASS: 240 distinct H.264 frames at 60fps (B frames: \(reordered)), four-second lookahead within 96 MiB, playback-clock selection and teardown")
        print("PASS: explicit live stream reset, stale compressed input rejection, same-codec/time restart")
    }

    static func videoPriorityCheck() {
        // Stall the actual text worker, then verify distinct VIDEO pixels keep
        // arriving at 60 Hz. Counting duplicate composite submissions misses this bug.
        let textQueue = DispatchQueue(label: "check.pip.blocked-text")
        textQueue.suspend()
        let textRenderer = PiPAsyncDanmakuRenderer(queue: textQueue)
        let frames = (0..<90).map { index -> CVPixelBuffer in
            let frame = makePixel()
            CVPixelBufferLockBaseAddress(frame, [])
            CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)[0] = UInt8(index)
            CVPixelBufferUnlockBaseAddress(frame, [])
            return frame
        }
        let probe = PumpProbe(pixel: frames[0], fixtures: frames)
        let snapshot = PiPDanmakuSnapshot(messages: (0..<160).map { message("密集弹幕 \($0)") },
                                         isVisible: true, sourceID: "video-priority")
        let pump = PiPFramePump(timebase: nil, danmakuRenderer: textRenderer,
            isReady: { true }, enqueue: { probe.receive($0) }, flush: {})
        pump.start(generation: 1) { token in
            let now = CACurrentMediaTime()
            let frame = probe.read { value in
                defer { value.requested += 1 }
                return value.fixtures[value.requested % value.fixtures.count]
            }
            pump.submit(.init(frame: frame, snapshot: snapshot, hostTime: now,
                              mediaTime: CMTime(seconds: now, preferredTimescale: 60_000), rate: 1), generation: token)
        }
        Thread.sleep(forTimeInterval: 1)
        let count = probe.read { $0.count }
        let unique = probe.read { Set($0.videoMarkers).count }
        // Allow scheduling noise, but a 30fps acquisition ceiling must fail.
        precondition(count >= 50 && unique >= 50, "Blocked text must not reduce VIDEO to 30fps: \(unique)/\(count)")
        textQueue.resume()
        textQueue.sync {}
        let resumedAt = probe.read { $0.videoMarkers.count }
        Thread.sleep(forTimeInterval: 1)
        pump.stop()
        let resumedUnique = probe.read { Set($0.videoMarkers.dropFirst(resumedAt)).count }
        precondition(resumedUnique >= 50, "Active dense text must also preserve fresh video cadence")
        print("PASS: blocked danmaku worker: \(unique) distinct video frames / \(count) submissions in 1s")
        print("PASS: active dense danmaku: \(resumedUnique) distinct video frames in 1s")
    }

    static func overlayCheck(_ pixel: CVPixelBuffer) {
        let queue = DispatchQueue(label: "check.pip.overlay")
        let renderer = PiPAsyncDanmakuRenderer(queue: queue)
        let compositor = PiPFrameCompositor()
        let size = PiPFrameCompositor.size(for: pixel)
        var snapshot = PiPDanmakuSnapshot(messages: [message("异步透明弹幕")], isVisible: true, sourceID: "overlay")
        _ = renderer.image(snapshot: snapshot, size: size, at: 0)
        queue.sync {}
        _ = renderer.image(snapshot: snapshot, size: size, at: 1)
        queue.sync {}
        let overlay = renderer.image(snapshot: snapshot, size: size, at: 2)
        precondition(overlay != nil)
        queue.sync {}
        let composed = compositor.compose(pixel, overlay: overlay, at: 2)!
        let plain = pixels(pixel)
        let painted = pixels(CMSampleBufferGetImageBuffer(composed)!)
        precondition(plain != painted, "The independently rendered overlay must appear on video")
        precondition(plain.suffix(CVPixelBufferGetBytesPerRow(pixel) * 100)
                     == painted.suffix(CVPixelBufferGetBytesPerRow(pixel) * 100), "Overlay must preserve the video below it")

        snapshot.isPaused = true
        _ = renderer.image(snapshot: snapshot, size: size, at: 2)
        queue.sync {}
        let frozen = renderer.image(snapshot: snapshot, size: size, at: 100)!
        queue.sync {}
        let stillFrozen = renderer.image(snapshot: snapshot, size: size, at: 101)!
        queue.sync {}
        let pausedA = compositor.compose(pixel, overlay: frozen, at: 100)!
        let pausedB = compositor.compose(pixel, overlay: stillFrozen, at: 101)!
        precondition(pixels(CMSampleBufferGetImageBuffer(pausedA)!) == pixels(CMSampleBufferGetImageBuffer(pausedB)!),
                     "An asynchronous overlay must freeze when paused")

        // A hide/show cycle while a render is in flight must not resurrect it,
        // even when the final settings key equals the original key.
        queue.suspend()
        _ = renderer.image(snapshot: snapshot, size: size, at: 102)
        snapshot.isVisible = false
        precondition(renderer.image(snapshot: snapshot, size: size, at: 102) == nil)
        snapshot.isVisible = true
        precondition(renderer.image(snapshot: snapshot, size: size, at: 102) == nil)
        queue.resume()
        queue.sync {}
        precondition(renderer.image(snapshot: snapshot, size: size, at: 103) == nil,
                     "A superseded render cannot return after hide/show")
        queue.sync {}
        snapshot.clearToken += 1
        snapshot.messages = []
        precondition(renderer.image(snapshot: snapshot, size: size, at: 104) == nil)
        queue.sync {}
        snapshot.sourceID = "new-source"
        precondition(renderer.image(snapshot: snapshot, size: size, at: 105) == nil)
        queue.sync {}
        renderer.reset()
        precondition(renderer.image(snapshot: snapshot, size: size, at: 106) == nil)
        queue.sync {}
        print("PASS: asynchronous overlay pixels, pause, immediate hide/seek/source/reset invalidation and stale render rejection")
    }
}
