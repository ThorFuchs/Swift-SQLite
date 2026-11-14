// SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A value protected by a `pthread_mutex_t`.
///
/// SQLiteSwift uses it instead of `Synchronization.Mutex` because ThreadSanitizer
/// sees `pthread_mutex_lock` on every platform. On Linux, `Mutex` locks with futex
/// calls inside the uninstrumented standard library, so ThreadSanitizer would report
/// every protected access as a race and real races could not be told apart.
package final class SQLiteLocked<State> {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private var state: State

    package init(_ state: State) {
        self.state = state
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(mutex, nil)
        precondition(result == 0, "pthread_mutex_init failed: \(result)")
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    /// Runs `body` with exclusive access to the state.
    package func withLock<Result, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body(&state)
    }
}

// The state is only reached through `withLock`, which serializes all access.
extension SQLiteLocked: @unchecked Sendable where State: Sendable {}
