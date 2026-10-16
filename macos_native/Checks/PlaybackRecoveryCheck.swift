import Foundation

@main
struct PlaybackRecoveryCheck {
    static func main() {
        // Actual log pattern: five stable minutes, then repeated HTTP 200 + a few
        // seconds of video + EOF. It must progress 1 -> 2 -> fresh URL, not 1 forever.
        var policy = PlaybackRecoveryPolicy()
        policy.beginAttempt()
        policy.playbackStarted(at: 0)
        precondition(policy.nextSameURLAttempt(at: 304) == 1)
        policy.beginAttempt()
        policy.playbackStarted(at: 305)
        precondition(policy.nextSameURLAttempt(at: 309) == 2)
        policy.beginAttempt()
        policy.playbackStarted(at: 310)
        precondition(policy.nextSameURLAttempt(at: 314) == nil)
        print("PASS: logged short-connection loop escalates to a fresh URL")

        for cycle in 1...3 {
            precondition(policy.nextFreshStreamCycle() == cycle)
            for attempt in 1...2 {
                policy.beginAttempt()
                policy.playbackStarted(at: 400)
                precondition(policy.nextSameURLAttempt(at: 405) == attempt)
            }
            policy.beginAttempt()
            policy.playbackStarted(at: 410)
            precondition(policy.nextSameURLAttempt(at: 414) == nil)
        }
        precondition(policy.nextFreshStreamCycle() == nil)
        print("PASS: first frames do not reset the bounded fresh-URL budget")

        policy.beginAttempt()
        policy.playbackStarted(at: 500)
        policy.playbackStarted(at: 529) // repeated notifications must not move the start time
        precondition(policy.nextSameURLAttempt(at: 530) == 1)
        precondition(policy.freshStreamCycles == 0)
        print("PASS: sustained playback restores retry budgets")

        var empty = PlaybackRecoveryPolicy()
        for attempt in 1...2 {
            empty.beginAttempt()
            precondition(empty.nextSameURLAttempt(at: 10_000) == attempt)
        }
        empty.beginAttempt()
        precondition(empty.nextSameURLAttempt(at: 10_000) == nil)
        print("PASS: connections without a frame never count as stable playback")
    }
}
