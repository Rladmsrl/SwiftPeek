import Foundation

@main
struct GenerationGateCheck {
    @MainActor static func main() async {
        let gate = PlaybackGenerationGate()
        let old = gate.advance()
        let entered = DispatchGroup(); entered.enter()
        let releaseOperation = DispatchSemaphore(value: 0)
        let operationDone = DispatchGroup(); operationDone.enter()
        DispatchQueue.global().async {
            gate.withCurrent(old) {
                entered.leave()
                precondition(releaseOperation.wait(timeout: .now() + 3) == .success)
            }
            operationDone.leave()
        }
        precondition(entered.wait(timeout: .now() + 3) == .success)
        let advanceDone = DispatchGroup(); advanceDone.enter()
        DispatchQueue.global().async { _ = gate.advance(); advanceDone.leave() }
        precondition(advanceDone.wait(timeout: .now() + 0.05) == .timedOut)
        releaseOperation.signal()
        precondition(operationDone.wait(timeout: .now() + 3) == .success)
        precondition(advanceDone.wait(timeout: .now() + 3) == .success)
        precondition(gate.withCurrent(old) { true } == nil)
        print("PASS: stop/reset waits for in-flight enqueue and rejects later old operations")

        for _ in 0..<1000 {
            let previous = gate.current
            let current = gate.advance()
            let producers = DispatchGroup()
            for _ in 0..<4 {
                producers.enter()
                DispatchQueue.global().async {
                    precondition(gate.withCurrent(previous) { true } == nil)
                    producers.leave()
                }
            }
            precondition(gate.withCurrent(current) { true } == true)
            precondition(producers.wait(timeout: .now() + 3) == .success)
        }
        print("PASS: 1000 stop/restart cycles reject 4000 stale render operations")
        let flushQueue = PlaybackFlushQueue()
        var events: [Int] = []
        var finishOldFlush: CheckedContinuation<Void, Never>?
        flushQueue.enqueue {
            events.append(1)
            await withCheckedContinuation { finishOldFlush = $0 }
            events.append(2)
        }
        for _ in 0..<1000 {
            if finishOldFlush != nil { break }
            await Task.yield()
        }
        precondition(finishOldFlush != nil)
        let newFlush = flushQueue.enqueue { events.append(3) }
        for _ in 0..<20 { await Task.yield() }
        precondition(events == [1], "New flush ran while the old flush was pending")
        finishOldFlush?.resume()
        await newFlush.value
        precondition(events == [1, 2, 3])
        print("PASS: new playback barrier waits for the old asynchronous flush")

    }
}
