import CoreMedia

enum LiveHandoffTimeline {
    /// Both streams can start their FLV timestamps at zero. Map the new keyframe
    /// after the last queued audio/video sample, without resetting the shared clock.
    static func continuationOffset(end: CMTime, clock: CMTime) -> CMTime {
        CMTimeMaximum(end, CMTimeAdd(clock, CMTime(seconds: 0.05, preferredTimescale: 1000)))
    }
}
