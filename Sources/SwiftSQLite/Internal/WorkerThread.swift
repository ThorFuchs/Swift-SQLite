// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSwiftSQLite
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A dedicated OS thread that runs one connection's blocking SQLite calls.
///
/// Jobs run in FIFO order. ``stopAndJoin()`` lets queued jobs finish, then joins the
/// thread. The cooperative thread pool never runs SQLite calls.
final class SQLiteWorkerThread: @unchecked Sendable {
    typealias Job = @Sendable () -> Void

    private let shared: WorkerShared
    private let thread: pthread_t
    // Guarded by shared.mutex.
    private var joined = false

    /// Starts the thread. Fails only if the OS refuses to create a thread.
    init(name: String) throws(SQLiteError) {
        let shared = WorkerShared(name: name)
        self.shared = shared
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, 1 << 20)
        let context = Unmanaged.passRetained(shared).toOpaque()
        #if canImport(Darwin) || canImport(Musl)
        var handle: pthread_t? = nil
        #else
        var handle = pthread_t()
        #endif
        let result = pthread_create(&handle, &attributes, workerEntry, context)
        #if canImport(Darwin) || canImport(Musl)
        guard result == 0, let started = handle else {
            Unmanaged<WorkerShared>.fromOpaque(context).release()
            throw .sqlite(SQLiteErrorDetails(code: SQLiteResultCode(rawValue: 1), message: "pthread_create failed: \(result)"))
        }
        thread = started
        #else
        guard result == 0 else {
            Unmanaged<WorkerShared>.fromOpaque(context).release()
            throw .sqlite(SQLiteErrorDetails(code: SQLiteResultCode(rawValue: 1), message: "pthread_create failed: \(result)"))
        }
        thread = handle
        #endif
    }

    deinit {
        stopAndJoin()
    }

    /// Queues a job. Returns `false` if the thread is stopping.
    @discardableResult
    func enqueue(_ job: @escaping Job) -> Bool {
        shared.lock()
        defer { shared.unlock() }
        guard !shared.stopping else { return false }
        shared.jobs.append(job)
        pthread_cond_signal(shared.condition)
        return true
    }

    /// `true` when the calling code runs on this worker thread.
    var isCurrent: Bool {
        pthread_equal(pthread_self(), thread) != 0
    }

    /// `true` once the thread's run loop has returned.
    var hasExited: Bool {
        shared.lock()
        defer { shared.unlock() }
        return shared.exited
    }

    /// Stops accepting jobs, lets queued jobs finish and joins the thread.
    ///
    /// If called on the worker thread itself (only possible when the last reference
    /// is released by a job), the thread is detached instead and exits after the
    /// current job.
    func stopAndJoin() {
        shared.lock()
        shared.stopping = true
        pthread_cond_signal(shared.condition)
        let alreadyJoined = joined
        joined = true
        shared.unlock()
        guard !alreadyJoined else { return }
        if isCurrent {
            pthread_detach(thread)
        } else {
            pthread_join(thread, nil)
        }
    }
}

#if canImport(Darwin)
private func workerEntry(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    Unmanaged<WorkerShared>.fromOpaque(context).takeRetainedValue().runLoop()
    return nil
}
#else
private func workerEntry(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    Unmanaged<WorkerShared>.fromOpaque(context!).takeRetainedValue().runLoop()
    return nil
}
#endif

/// State shared between the owner and the thread, guarded by `mutex`.
private final class WorkerShared: @unchecked Sendable {
    let mutex: UnsafeMutablePointer<pthread_mutex_t>
    let condition: UnsafeMutablePointer<pthread_cond_t>
    var jobs: [SQLiteWorkerThread.Job] = []
    var stopping = false
    var exited = false
    let name: String

    init(name: String) {
        self.name = name
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        condition = .allocate(capacity: 1)
        condition.initialize(to: pthread_cond_t())
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        condition.deinitialize(count: 1)
        condition.deallocate()
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }

    func runLoop() {
        setCurrentThreadName(name)
        while true {
            lock()
            while jobs.isEmpty && !stopping {
                pthread_cond_wait(condition, mutex)
            }
            if jobs.isEmpty {
                exited = true
                unlock()
                return
            }
            let job = jobs.removeFirst()
            unlock()
            job()
        }
    }
}

private func setCurrentThreadName(_ name: String) {
    #if canImport(Darwin)
    _ = pthread_setname_np(name)
    #elseif os(Linux)
    // glibc hides pthread_setname_np without _GNU_SOURCE; use the C wrapper.
    _ = cswiftsqlite_set_current_thread_name(name)
    #endif
}

/// Reads the calling thread's name (used by tests to prove where code runs).
func currentThreadName() -> String {
    var buffer = [CChar](repeating: 0, count: 64)
    #if canImport(Darwin)
    _ = pthread_getname_np(pthread_self(), &buffer, buffer.count)
    #elseif os(Linux)
    _ = cswiftsqlite_get_current_thread_name(&buffer, buffer.count)
    #endif
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
