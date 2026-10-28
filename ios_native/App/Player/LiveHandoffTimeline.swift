import CoreMedia

enum LiveHandoffTimeline {
    /// A replacement starting this far after the last delivered frame is a short
    /// hold the clock walks through; further means a different timebase.
    static let maximumSpliceGapMS: Int64 = 300
    /// A replacement starting this far before is an overlap worth hiding; further
    /// back is treated as a different timebase.
    static let maximumSpliceOverlapMS: Int64 = 10_000

    /// Both streams can start their FLV timestamps at zero. Map the new keyframe
    /// after the last queued audio/video sample, without resetting the shared clock.
    static func continuationOffset(end: CMTime, clock: CMTime) -> CMTime {
        CMTimeMaximum(end, CMTimeAdd(clock, CMTime(seconds: 0.05, preferredTimescale: 1000)))
    }

    /// Connections to the same origin usually share FLV timestamps. When the
    /// replacement's first keyframe is close to the last delivered video
    /// timestamp, keep the old timeline: frames up to the returned cut are decoded
    /// without being shown, so the handoff neither repeats nor skips content.
    ///
    /// Rebased streams (every connection starting near zero) can look aligned by
    /// coincidence early on, so the old timeline must be absolute, and the
    /// replacement must already hold media past the cut or the picture would wait
    /// for the live edge. Returns nil when the timelines cannot be aligned.
    static func spliceCut(lastVideo: UInt32?, previousBase: UInt32?, replacementStart: UInt32?, replacementEnd: UInt32?) -> UInt32? {
        guard let lastVideo, let previousBase, let replacementStart, let replacementEnd,
              Int64(previousBase) > maximumSpliceOverlapMS else { return nil }
        let lead = Int64(replacementStart) - Int64(lastVideo)
        guard lead <= maximumSpliceGapMS, lead >= -maximumSpliceOverlapMS,
              Int64(replacementEnd) - Int64(lastVideo) >= minimumSplicePlayableMS else { return nil }
        return lastVideo
    }

    /// Media the replacement must already hold beyond the cut.
    static let minimumSplicePlayableMS: Int64 = 500
}
