import Foundation

/// Fixed-capacity ring buffer of Float samples with drop-oldest overflow.
///
/// This is the *only* data structure the audio tap callback touches (plus a
/// watchdog timestamp): the real-time audio thread must never allocate
/// unboundedly, run inference, touch SwiftData or hop to the main actor.
/// When the consumer falls behind, the oldest audio is dropped and counted —
/// a dropped block shortens the transcript timeline but never crashes or
/// grows memory without bound.
final class AudioRingBuffer: @unchecked Sendable {
    /// A suspended `waitForData` call. The box makes the waiter identifiable
    /// so the timeout path and the append path never resume it twice.
    private final class Waiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Int, Never>?

        init(_ continuation: CheckedContinuation<Int, Never>) {
            self.continuation = continuation
        }

        var isPending: Bool { continuation != nil }

        func resume(_ value: Int) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private var storage: [Float]
    private var head = 0   // index of oldest sample
    private var count = 0
    private let lock = NSLock()
    private var waiters: [Waiter] = []

    private var droppedCount = 0
    private var appendedCount = 0
    private var lastAppendDate: Date?

    init(capacitySamples: Int) {
        precondition(capacitySamples > 0, "capacity must be positive")
        storage = [Float](repeating: 0, count: capacitySamples)
    }

    var capacity: Int { storage.count }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Total samples dropped because the buffer was full.
    var droppedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    /// Total samples ever appended.
    var appendedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return appendedCount
    }

    /// Wall-clock time of the most recent append — the watchdog's signal
    /// that the tap is still delivering audio.
    var lastAppendAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastAppendDate
    }

    /// Append samples, dropping the oldest when full. Safe to call from the
    /// real-time audio thread.
    func append(_ samples: ArraySlice<Float>) {
        appendSequence(samples)
    }

    func append(_ samples: [Float]) {
        appendSequence(samples)
    }

    /// Zero-copy path from the tap's converted buffer.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        appendSequence(samples)
    }

    private func appendSequence<S: Collection>(_ samples: S) where S.Element == Float {
        guard !samples.isEmpty else { return }
        lock.lock()
        let capacity = storage.count
        appendedCount += samples.count
        lastAppendDate = Date()
        var dropped = 0
        for value in samples {
            if count == capacity {
                head = (head + 1) % capacity
                count -= 1
                dropped += 1
            }
            storage[(head + count) % capacity] = value
            count += 1
        }
        droppedCount += dropped
        let currentCount = count
        let boxes = waiters
        waiters = []
        lock.unlock()
        for box in boxes where currentCount > 0 {
            box.resume(currentCount)
        }
    }

    /// Remove and return up to `maxCount` samples (oldest first).
    func read(upTo maxCount: Int) -> [Float] {
        precondition(maxCount >= 0)
        lock.lock(); defer { lock.unlock() }
        let n = Swift.min(maxCount, count)
        guard n > 0 else { return [] }
        var result = [Float]()
        result.reserveCapacity(n)
        if head + n <= storage.count {
            result.append(contentsOf: storage[head..<(head + n)])
        } else {
            let first = storage.count - head
            result.append(contentsOf: storage[head...])
            result.append(contentsOf: storage[0..<(n - first)])
        }
        head = (head + n) % storage.count
        count -= n
        return result
    }

    /// Remove and return exactly `n` samples, or nil if fewer are available.
    /// Assumes a single consumer (the pump task).
    func read(exactly n: Int) -> [Float]? {
        lock.lock()
        let enough = count >= n
        lock.unlock()
        guard enough else { return nil }
        return read(upTo: n)
    }

    /// Discard everything.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        head = 0
        count = 0
    }

    /// Atomically: data already available, or the waiter is registered and
    /// the caller must suspend. Non-async by design — the lock is never
    /// held across an await.
    private func claimAvailableOrRegister(_ box: Waiter) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if count > 0 { return count }
        waiters.append(box)
        return nil
    }

    /// Suspend until at least one sample is available. Returns the number
    /// available, or 0 if `timeout` elapsed with no data.
    func waitForData(timeout: TimeInterval? = nil) async -> Int {
        // Never wait forever without a way out for a stopped producer —
        // callers that pass nil must couple the wait with cancellation.
        let effectiveTimeout = timeout ?? 60
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let box = Waiter(continuation)
            if let availableNow = claimAvailableOrRegister(box) {
                box.resume(availableNow)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout) { [weak self, box] in
                guard let self else { return }
                self.lock.lock()
                guard let index = self.waiters.firstIndex(where: { $0 === box }) else {
                    // append() already resumed this waiter.
                    self.lock.unlock()
                    return
                }
                self.waiters.remove(at: index)
                let n = self.count
                self.lock.unlock()
                box.resume(n)
            }
        }
    }
}
