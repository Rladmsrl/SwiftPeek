import AVFoundation
import VideoToolbox

/// Advance a sampling deadline instead of waiting a full interval after the
/// last accepted source frame. The latter turns 30 fps input / 24 fps output
/// into 15 fps and also loses frames to floating-point rounding at 30 fps.
struct PiPVideoSamplingClock {
    private var nextTime: TimeInterval?
    mutating func accepts(_ time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        let step = 1 / 30.0
        if let nextTime, time + 0.000_001 < nextTime { return false }
        if let nextTime {
            self.nextTime = nextTime + (floor(max(0, time - nextTime) / step) + 1) * step
        } else {
            nextTime = time + step
        }
        return true
    }
}

/// Optional second decoder for iOS PiP composition. The normal live renderer and
/// audio clock stay untouched. Decode input is serialized; output is bounded to
/// the live player's buffer budget and selected using that same audio clock.
final class PiPLiveFrameSource: @unchecked Sendable {
    private let decodeLock = NSLock()
    private let frameLock = NSLock()
    private let processingLock = NSLock()
    private var enabled = false
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var frames: [(CMTime, CVPixelBuffer)] = []
    private var lastInput = CMTime.invalid
    private var epoch = 0
    private var cadence = PiPVideoSamplingClock()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    func setEnabled(_ enabled: Bool) {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        resetDecoder()
    }

    private func resetDecoder() {
        // Decoder callbacks never acquire decodeLock; invalidate before clearing output state.
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        lastInput = .invalid
        frameLock.lock()
        epoch += 1
        frames.removeAll()
        frameLock.unlock()
        processingLock.lock()
        cadence = PiPVideoSamplingClock()
        pool = nil
        poolSize = .zero
        processingLock.unlock()
    }

    func append(_ sample: CMSampleBuffer) {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard enabled, let newFormat = CMSampleBufferGetFormatDescription(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: newFormat) }) == true
            || (lastInput.isValid && pts.seconds < lastInput.seconds - 1) {
            resetDecoder()
        }
        lastInput = pts
        if session == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat,
                                               decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                               outputCallback: nil, decompressionSessionOut: &session) == noErr else { return }
            format = newFormat
        }
        guard let session else { return }
        frameLock.lock()
        let token = epoch
        frameLock.unlock()
        // No asynchronous flag: avoid a growing queue of compressed input.
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, timestamp, _ in
            guard status == noErr, let image, let self else { return }
            self.processingLock.lock()
            defer { self.processingLock.unlock() }
            self.frameLock.lock()
            let current = token == self.epoch
            self.frameLock.unlock()
            guard current, self.cadence.accepts(timestamp.seconds), let small = self.downsample(image) else { return }
            // Scaling never holds the lock used by the playback/UI reader.
            self.frameLock.lock()
            defer { self.frameLock.unlock() }
            guard token == self.epoch else { return }
            self.frames.append((timestamp, small))
            self.frames.sort { $0.0 < $1.0 }
            // Reduced to 480 pixels / 30 fps before retaining; enough for the
            // live player's ~4-second lookahead without retaining full-size 4K frames.
            let bytes = max(1, CVPixelBufferGetDataSize(small))
            let limit = min(180, max(2, 96 * 1024 * 1024 / bytes))
            if self.frames.count > limit { self.frames.removeFirst(self.frames.count - limit) }
        }
    }

    // Called only while processingLock is held. Readers never acquire this lock.
    private func downsample(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        let scale = min(1, 480 / max(width, height))
        let size = CGSize(width: max(2, floor(width * scale / 2) * 2), height: max(2, floor(height * scale / 2) * 2))
        if size != poolSize {
            poolSize = size
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
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 184] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixel) == kCVReturnSuccess,
              let pixel else { return nil }
        guard PiPPixelTransfer.copy(frame, to: pixel) else { return nil }
        return pixel
    }

    func frame(at time: CMTime) -> CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard time.isValid, let index = frames.lastIndex(where: { $0.0 <= time }) else { return nil }
        let result = frames[index].1
        if index > 0 { frames.removeFirst(index) }
        return result
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
