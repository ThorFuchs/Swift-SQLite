// SPDX-License-Identifier: Apache-2.0

import Synchronization

/// A fixed set of slots (connection indexes) handed out one caller at a time.
///
/// Callers wait in FIFO order. A waiting caller whose task is cancelled leaves the
/// queue with ``SQLiteError/interrupted``. ``drain()`` closes the pool: waiters fail
/// with ``SQLiteError/closed`` and it returns once every slot is back.
final class SlotPool: Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Result<Int, SQLiteError>, Never>
    }

    private struct State: ~Copyable {
        var free: [Int]
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
        var closed = false
        var drainWaiter: CheckedContinuation<Void, Never>?
        let capacity: Int
    }

    private let state: Mutex<State>

    init(capacity: Int) {
        state = Mutex(State(free: Array((0..<capacity).reversed()), capacity: capacity))
    }

    /// The number of slots currently handed out (for tests and diagnostics).
    var inUse: Int {
        state.withLock { $0.capacity - $0.free.count }
    }

    func acquire() async throws(SQLiteError) -> Int {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        let result: Result<Int, SQLiteError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    if state.closed {
                        continuation.resume(returning: .failure(.closed))
                    } else if Task.isCancelled {
                        continuation.resume(returning: .failure(.interrupted))
                    } else if let slot = state.free.popLast() {
                        continuation.resume(returning: .success(slot))
                    } else {
                        state.waiters.append(Waiter(id: id, continuation: continuation))
                    }
                }
            }
        } onCancel: {
            state.withLock { state in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                    let waiter = state.waiters.remove(at: index)
                    waiter.continuation.resume(returning: .failure(.interrupted))
                }
            }
        }
        return try result.get()
    }

    func release(_ slot: Int) {
        state.withLock { state in
            if !state.closed, !state.waiters.isEmpty {
                let waiter = state.waiters.removeFirst()
                waiter.continuation.resume(returning: .success(slot))
                return
            }
            state.free.append(slot)
            if state.closed, state.free.count == state.capacity, let drain = state.drainWaiter {
                state.drainWaiter = nil
                drain.resume()
            }
        }
    }

    /// Closes the pool and waits until every slot has been released.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { state in
                state.closed = true
                let waiters = state.waiters
                state.waiters.removeAll()
                for waiter in waiters {
                    waiter.continuation.resume(returning: .failure(.closed))
                }
                if state.free.count == state.capacity {
                    continuation.resume()
                } else {
                    state.drainWaiter = continuation
                }
            }
        }
    }

    var isClosed: Bool {
        state.withLock { $0.closed }
    }
}
