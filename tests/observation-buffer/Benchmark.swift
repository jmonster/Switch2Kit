import Foundation
import Synchronization

@main enum Benchmark {
    static func main() {
        for capacity in [256, 4096] {
            var elapsed: [Double] = []
            for _ in 0..<9 {
                let queue = DispatchQueue(label: "buffer.benchmark")
                queue.suspend()
                let done = DispatchSemaphore(value: 0)
                let calls = Mutex(0)
                let box = EventMailbox(capacity: capacity, queue: queue, current: {
                    EventEnvelope(sequence: UInt64(capacity + 1), event: .snapshot(.init()), lifetime: nil)
                }, handler: { _ in
                    let count = calls.withLock { $0 += 1; return $0 }
                    if count == capacity { done.signal() }
                })
                for n in 1...capacity { box.enqueue(.init(sequence: UInt64(n), event: .status(.init()), lifetime: nil)) }
                let start = DispatchTime.now().uptimeNanoseconds
                queue.resume()
                precondition(done.wait(timeout: .now() + 20) == .success)
                elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                box.cancel(); queue.sync {}
                precondition(calls.withLock { $0 } == capacity)
            }
            print("capacity=\(capacity) median_drain_ms=\(elapsed.sorted()[4]) samples_ms=\(elapsed)")
        }
    }
}
