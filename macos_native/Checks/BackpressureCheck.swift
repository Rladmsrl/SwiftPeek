import Foundation

/// Pure Foundation regression checks: no app launch, windows, network or playback.
@main
struct BackpressureCheck {
    static func main() {
        // Closing a full receiver discards buffered chunks without acknowledgements.
        // The old DispatchSemaphore crashed at disposal for this exact lifecycle.
        for _ in 0..<1000 {
            let gate = HTTPStreamBackpressure(capacity: 64)
            for _ in 0..<64 { precondition(gate.acquire()) }
            gate.cancel()
            gate.cancel()
            gate.release() // a consumer may finish its current chunk after cancellation
            precondition(!gate.acquire())
        }
        print("PASS: 1000 cancellations with unacknowledged buffered chunks")

        // Backpressure must still block before cancellation or acknowledgement.
        let gate = HTTPStreamBackpressure(capacity: 1)
        precondition(gate.acquire())
        let entered = DispatchGroup()
        let finished = DispatchGroup()
        entered.enter()
        finished.enter()
        DispatchQueue.global().async {
            entered.leave()
            precondition(gate.acquire())
            gate.release()
            finished.leave()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        precondition(finished.wait(timeout: .now() + 0.05) == .timedOut)
        gate.release()
        precondition(finished.wait(timeout: .now() + 2) == .success)
        gate.cancel()
        print("PASS: acknowledgement resumes a blocked producer")

        // Cancellation must wake every waiter, even with zero consumer progress.
        let cancelledGate = HTTPStreamBackpressure(capacity: 1)
        precondition(cancelledGate.acquire())
        let waiters = DispatchGroup()
        let ready = DispatchGroup()
        for _ in 0..<8 {
            waiters.enter()
            ready.enter()
            DispatchQueue.global().async {
                ready.leave()
                precondition(!cancelledGate.acquire())
                waiters.leave()
            }
        }
        precondition(ready.wait(timeout: .now() + 2) == .success)
        precondition(waiters.wait(timeout: .now() + 0.05) == .timedOut)
        cancelledGate.cancel()
        precondition(waiters.wait(timeout: .now() + 2) == .success)
        print("PASS: cancellation releases all blocked producers")
    }
}
