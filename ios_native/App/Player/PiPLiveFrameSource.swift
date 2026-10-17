import AVFoundation
import CoreImage
import VideoToolbox

/// Optional second decoder for iOS PiP composition. The normal live renderer and
/// audio clock stay untouched. Decode input is serialized; output is bounded to
/// the live player's buffer budget and selected using that same audio clock.
final class PiPLiveFrameSource: @unchecked Sendable {
    private let decodeLock = NSLock()
    private let frameLock = NSLock()
    private var enabled = false
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var frames: [(CMTime, CVPixelBuffer)] = []
    private var lastInput = CMTime.invalid
    private var epoch = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastStoredTime = -Double.infinity
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
        // Decoder callbacks only acquire frameLock, never decodeLock.
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        lastInput = .invalid
        frameLock.lock()
        lastStoredTime = -Double.infinity
        pool = nil
        poolSize = .zero
        epoch += 1
        frames.removeAll()
        frameLock.unlock()
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
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
            self.frameLock.lock()
            defer { self.frameLock.unlock() }
            guard token == self.epoch else { return }
            guard timestamp.seconds >= self.lastStoredTime + 1 / 24.0,
                  let small = self.downsample(image) else { return }
            self.lastStoredTime = timestamp.seconds
            self.frames.append((timestamp, small))
            self.frames.sort { $0.0 < $1.0 }
            // Reduced to 480 pixels / 24 fps before retaining; enough for the
            // live player's ~4-second lookahead without retaining full-size 4K frames.
            let bytes = max(1, CVPixelBufferGetDataSize(small))
            let limit = min(180, max(2, 96 * 1024 * 1024 / bytes))
            if self.frames.count > limit { self.frames.removeFirst(self.frames.count - limit) }
        }
    }

    // Called with frameLock held, including from decoder callbacks.
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
        context.render(CIImage(cvPixelBuffer: frame).transformed(by: .init(scaleX: size.width / width, y: size.height / height)),
                       to: pixel, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
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
