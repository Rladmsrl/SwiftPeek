import AVFoundation
import VideoToolbox
import SimpleLiveKit

/// Bound sampling by presentation-time slots, not callback order. H.264 B frames
/// can arrive after a reference frame with a later PTS; a monotonic deadline
/// would discard most of those valid frames before the sorted cache sees them.
struct PiPVideoSamplingClock {
    private var origin: TimeInterval?
    private var newestSlot: Int64 = 0
    private var lastPrunedSlot: Int64 = 0
    private var retainedSlots = Set<Int64>()
    mutating func accepts(_ time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        if origin == nil { origin = time }
        // Accommodate FLV's 1 ms timestamp quantization relative to the first
        // decoded frame. Slots behind the latest one remain eligible for B frames.
        let value = floor((time - origin! + 0.001_001) * 60)
        guard value >= Double(Int64.min), value < Double(Int64.max) else { return false }
        let slot = Int64(value)
        newestSlot = max(newestSlot, slot)
        // Ten seconds is far beyond a normal reorder window; keep bookkeeping
        // bounded even for long streams. Explicit stream resets create a new clock.
        guard slot >= newestSlot - 600 else { return false }
        if retainedSlots.count >= 600, newestSlot - lastPrunedSlot >= 60 {
            retainedSlots = retainedSlots.filter { $0 >= newestSlot - 600 }
            lastPrunedSlot = newestSlot
        }
        return retainedSlots.insert(slot).inserted
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
    private var streamGeneration: UInt64 = 0
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var frames: [(CMTime, CVPixelBuffer)] = []
    private var lastInput = CMTime.invalid
    private var epoch = 0
    private var cadence = PiPVideoSamplingClock()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var sourceSize = CGSize.zero
    // Four seconds at 60 fps plus pool/reader headroom, within the same budget.
    private static let retainedFrames = 240
    private static let poolFrames = retainedFrames + 4
    private static let memoryBudget = 96 * 1024 * 1024
    // Guarded by frameLock. These distinguish decoder starvation from a cache
    // that has raced ahead of the audio clock; neither shows up as render cost.
    private var reportStart = ProcessInfo.processInfo.systemUptime
    private var decodeInputs = 0
    private var decodeOutputs = 0
    private var decodeFailures = 0
    private var samplingDrops = 0
    private var cacheEvictions = 0
    private var frameMisses = 0
    private var lastDecodeStatus: OSStatus = noErr

    func setEnabled(_ enabled: Bool) {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        resetDecoder()
    }

    var revision: Int {
        frameLock.lock()
        defer { frameLock.unlock() }
        return epoch
    }

    /// A playback restart/resync can reuse the exact same codec and timestamps.
    /// Invalidate explicitly; timestamp heuristics cannot identify every restart.
    func reset(streamGeneration: UInt64) {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        self.streamGeneration = streamGeneration
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
        sourceSize = .zero
        processingLock.unlock()
    }

    private static func isDecodeOnly(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true
    }

    func append(_ sample: CMSampleBuffer, generation: UInt64 = 0) {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard enabled, generation == streamGeneration,
              let newFormat = CMSampleBufferGetFormatDescription(sample) else { return }
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
        decodeInputs += 1
        let token = epoch
        frameLock.unlock()
        // No asynchronous flag: avoid a growing queue of compressed input.
        // Handoff overlap frames only rebuild decoder references; the main renderer hides them too.
        let flags: VTDecodeFrameFlags = Self.isDecodeOnly(sample) ? [._DoNotOutputFrame] : []
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) { [weak self] status, _, image, timestamp, _ in
            guard let self else { return }
            self.frameLock.lock()
            if status == noErr, image != nil { self.decodeOutputs += 1 }
            else { self.decodeFailures += 1; self.lastDecodeStatus = status }
            self.frameLock.unlock()
            guard status == noErr, let image else { return }
            self.processingLock.lock()
            defer { self.processingLock.unlock() }
            self.frameLock.lock()
            let current = token == self.epoch
            self.frameLock.unlock()
            guard current else { return }
            guard self.cadence.accepts(timestamp.seconds) else {
                self.frameLock.lock()
                self.samplingDrops += 1
                self.frameLock.unlock()
                return
            }
            guard let small = self.downsample(image) else { return }
            // Scaling never holds the lock used by the playback/UI reader.
            self.frameLock.lock()
            defer { self.frameLock.unlock() }
            guard token == self.epoch else { return }
            self.frames.append((timestamp, small))
            self.frames.sort { $0.0 < $1.0 }
            // Keep the complete 60 fps lookahead. Resolution is bounded by the
            // actual surface allocation size, instead of evicting unplayed frames.
            let bytes = max(1, CVPixelBufferGetDataSize(small))
            let limit = min(Self.retainedFrames, max(2, Self.memoryBudget / bytes))
            if self.frames.count > limit {
                self.cacheEvictions += self.frames.count - limit
                self.frames.removeFirst(self.frames.count - limit)
            }
        }
        if decodeStatus != noErr {
            frameLock.lock()
            decodeFailures += 1
            lastDecodeStatus = decodeStatus
            frameLock.unlock()
        }
    }

    // Called only while processingLock is held. Readers never acquire this lock.
    private func downsample(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(frame)), height = CGFloat(CVPixelBufferGetHeight(frame))
        let scale = min(1, 480 / max(width, height))
        let inputSize = CGSize(width: width, height: height)
        if inputSize != sourceSize {
            sourceSize = inputSize
            poolSize = CGSize(width: max(2, floor(width * scale / 2) * 2), height: max(2, floor(height * scale / 2) * 2))
            pool = nil
        }
        while true {
            if pool == nil {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(poolSize.width),
                    kCVPixelBufferHeightKey as String: Int(poolSize.height),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
                CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            }
            guard let pool else { return nil }
            var pixel: CVPixelBuffer?
            let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: Self.poolFrames] as CFDictionary
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixel) == kCVReturnSuccess,
                  let pixel else { return nil }
            let bytes = max(1, CVPixelBufferGetDataSize(pixel))
            if bytes > Self.memoryBudget / Self.poolFrames {
                // Include IOSurface row/page alignment in the budget. This runs
                // only when establishing a new source size; subsequent frames reuse it.
                let reduction = sqrt(Double(Self.memoryBudget) / Double(Self.poolFrames * bytes)) * 0.95
                let smaller = CGSize(width: max(2, floor(poolSize.width * reduction / 2) * 2),
                                     height: max(2, floor(poolSize.height * reduction / 2) * 2))
                guard smaller != poolSize else { return nil }
                poolSize = smaller
                self.pool = nil
                continue
            }
            guard PiPPixelTransfer.copy(frame, to: pixel) else { return nil }
            return pixel
        }
    }

    func frame(at time: CMTime) -> CVPixelBuffer? {
        frameLock.lock()
        defer { report(at: time); frameLock.unlock() }
        guard time.isValid, let index = frames.lastIndex(where: { $0.0 <= time }) else {
            frameMisses += 1
            return nil
        }
        let result = frames[index].1
        if index > 0 { frames.removeFirst(index) }
        return result
    }

    private func report(at time: CMTime) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - reportStart
        guard elapsed >= 5 else { return }
        LiveDiagnostics.record("pip.live.stats", fields: [
            "decodeInputFPS": String(format: "%.1f", Double(decodeInputs) / elapsed),
            "decodeOutputFPS": String(format: "%.1f", Double(decodeOutputs) / elapsed),
            "decodeFailures": String(decodeFailures), "decodeStatus": String(lastDecodeStatus),
            "samplingDrops": String(samplingDrops), "cacheEvictions": String(cacheEvictions),
            "frameMisses": String(frameMisses), "cachedFrames": String(frames.count),
            "oldestAheadMS": String(format: "%.1f", ((frames.first?.0.seconds ?? time.seconds) - time.seconds) * 1000),
            "newestAheadMS": String(format: "%.1f", ((frames.last?.0.seconds ?? time.seconds) - time.seconds) * 1000)
        ])
        reportStart = now
        decodeInputs = 0; decodeOutputs = 0; decodeFailures = 0
        lastDecodeStatus = noErr
        samplingDrops = 0; cacheEvictions = 0; frameMisses = 0
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
