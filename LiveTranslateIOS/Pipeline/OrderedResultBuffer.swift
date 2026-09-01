import Foundation

/// Reorders out-of-order completion into `sequenceID` order.
///
/// Translations run on a bounded concurrent pool and finish out of order;
/// persistence and UI display must still follow utterance order. Entries are
/// registered in order with `register`, completed with `complete`, and
/// `drain` releases every entry whose turn has come — the Swift reprise of
/// the reference project's `_drain_locked`.
struct OrderedResultBuffer<Element: Sendable>: Sendable {
    private let lock = NSLock()
    private var order: [Int] = []
    private var pending: [Int: Element] = [:]
    private var nextID: Int

    /// Starts expecting IDs from `firstExpected` (the first `sequenceID`
    /// registered).
    init(firstExpected: Int = 0) {
        nextID = firstExpected
    }

    /// Declare that `id` will arrive. Must be called in utterance order
    /// before the element itself is ready.
    func register(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        if !order.contains(id) { order.append(id) }
        nextID = order.first ?? nextID
    }

    /// Deposit a completed element. Returns the contiguous run of elements
    /// that became releasable, in order.
    @discardableResult
    func complete(_ id: Int, _ element: Element) -> [(id: Int, element: Element)] {
        lock.lock(); defer { lock.unlock() }
        pending[id] = element
        return drainLocked()
    }

    /// Release every element whose predecessors are all complete.
    private func drainLocked() -> [(id: Int, element: Element)] {
        var released: [(Int, Element)] = []
        while let first = order.first, let element = pending.removeValue(forKey: first) {
            order.removeFirst()
            released.append((first, element))
        }
        return released
    }

    /// All still-missing IDs, in expected order (diagnostics / flush).
    var awaiting: [Int] {
        lock.lock(); defer { lock.unlock() }
        return order
    }

    var depth: Int {
        lock.lock(); defer { lock.unlock() }
        return order.count
    }
}
