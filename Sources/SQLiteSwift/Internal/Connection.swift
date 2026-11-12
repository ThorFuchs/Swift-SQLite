// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum ConnectionRole: Sendable, Equatable {
    case writer
    case reader(Int)

    var threadName: String {
        switch self {
        case .writer: "sqliteswift.w"
        case .reader(let index): "sqliteswift.r\(index)"
        }
    }
}

/// Cancellation state of one job run on a connection.
final class SQLiteJobToken: Sendable {
    private let flag = Atomic<Bool>(false)

    func cancel() { flag.store(true, ordering: .sequentiallyConsistent) }
    var isCancelled: Bool { flag.load(ordering: .sequentiallyConsistent) }
}

/// A SQLite handle that may be passed to `sqlite3_interrupt` from another thread.
struct InterruptibleHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

struct InterruptState: ~Copyable {
    var current: SQLiteJobToken?
    var handle: InterruptibleHandle?
}

/// The SQLite connection handle and everything that must be used only on the
/// connection's worker thread.
final class SQLiteConnectionCore: @unchecked Sendable {
    let role: ConnectionRole
    let configuration: SQLiteConfiguration
    private(set) var db: OpaquePointer?
    let cache: SQLiteStatementCache
    /// The job running right now (worker thread only).
    var activeToken: SQLiteJobToken?
    /// Allows `BEGIN`/`COMMIT`/`ROLLBACK` while SQLiteSwift itself runs them.
    var allowTransactionControl = false
    private var busyStart = ContinuousClock.now
    /// Shared with other threads; guards `sqlite3_interrupt`.
    let interrupt = Mutex(InterruptState())

    init(role: ConnectionRole, configuration: SQLiteConfiguration) {
        self.role = role
        self.configuration = configuration
        self.cache = SQLiteStatementCache(capacity: configuration.limits.statementCacheCapacity)
    }

    // MARK: Open and close

    static func openFlags(role: ConnectionRole, configuration: SQLiteConfiguration) -> Int32 {
        var flags: Int32 = SQLITE_OPEN_EXRESCODE
        switch role {
        case .writer: flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        case .reader: flags |= SQLITE_OPEN_READONLY
        }
        if case .inMemory = configuration.storage {
            flags |= SQLITE_OPEN_MEMORY
        }
        #if os(iOS)
        if let protection = configuration.fileProtection {
            flags |= protection.openFlag
        }
        #endif
        return flags
    }

    var path: String {
        switch configuration.storage {
        case .file(let path): path
        case .inMemory: ":memory:"
        }
    }

    func open() throws(SQLiteError) {
        var handle: OpaquePointer?
        let flags = Self.openFlags(role: role, configuration: configuration)
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(handle)
            throw SQLiteError.make(code: rc, message: message)
        }
        db = handle
        sqlite3_extended_result_codes(handle, 1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_busy_handler(handle, busyCallback, context)
        sqlite3_set_authorizer(handle, authorizerCallback, context)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(configuration.limits.hardMaxResultBytes))
        let interruptible = InterruptibleHandle(pointer: handle)
        interrupt.withLock { $0.handle = interruptible }
    }

    /// Finalizes cached statements and closes the handle.
    func close() {
        cache.finalizeAll()
        interrupt.withLock { $0.handle = nil }
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    // MARK: Errors

    func error(_ code: Int32) -> SQLiteError {
        let primary = code & 0xFF
        if activeToken?.isCancelled == true, primary == SQLITE_BUSY || primary == SQLITE_INTERRUPT {
            return .interrupted
        }
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return SQLiteError.make(code: code, message: message)
    }

    func checkCancelled() throws(SQLiteError) {
        if activeToken?.isCancelled == true { throw .interrupted }
    }

    func handle() throws(SQLiteError) -> OpaquePointer {
        guard let db else { throw .closed }
        return db
    }

    // MARK: Busy handling

    fileprivate func onBusy(attempt: Int32) -> Int32 {
        let now = ContinuousClock.now
        if attempt == 0 { busyStart = now }
        if activeToken?.isCancelled == true { return 0 }
        let remaining = configuration.busyTimeout - (now - busyStart)
        guard remaining > .zero else { return 0 }
        let backoffMS: [Int64] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
        let stepMS = backoffMS[min(Int(attempt), backoffMS.count - 1)]
        let step = min(Duration.milliseconds(stepMS), remaining)
        let (seconds, attoseconds) = step.components
        let micros = seconds * 1_000_000 + attoseconds / 1_000_000_000_000
        usleep(UInt32(clamping: max(micros, 1)))
        return 1
    }

    fileprivate func authorize(action: Int32) -> Int32 {
        // SQLITE_TRANSACTION: BEGIN/COMMIT/ROLLBACK are owned by SQLiteSwift.
        if action == SQLITE_TRANSACTION && !allowTransactionControl {
            return SQLITE_DENY
        }
        return SQLITE_OK
    }

    // MARK: Internal statements

    /// Runs SQLiteSwift's own SQL (transaction control, pragmas). Not cached and not
    /// subject to the cancellation check.
    func execInternal(_ sql: String) throws(SQLiteError) {
        let db = try handle()
        allowTransactionControl = true
        defer { allowTransactionControl = false }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// Runs SQLiteSwift's own single-row query and returns the first column.
    func scalarInternal(_ sql: String) throws(SQLiteError) -> SQLiteValue {
        let db = try handle()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        switch step {
        case SQLITE_ROW: return Self.columnValue(statement, 0)
        case SQLITE_DONE: return .null
        default: throw error(step)
        }
    }

    /// Test hook: makes the next `commitTransaction()` fail after the transaction
    /// ended (a commit hook turns the COMMIT into a rollback). Worker thread only.
    var failNextCommitForTesting = false

    /// Commits the open transaction and reports the outcome truthfully.
    ///
    /// - If `COMMIT` fails while the transaction is still open on this connection, no
    ///   commit happened: the transaction is rolled back and the error is thrown as is.
    /// - If `COMMIT` fails and the transaction is no longer open, SQLiteSwift cannot know
    ///   whether it became durable: ``SQLiteError/commitOutcomeUnknown(_:)``.
    func commitTransaction() throws(SQLiteError) {
        let db = try handle()
        let injectFailure = failNextCommitForTesting
        failNextCommitForTesting = false
        if injectFailure {
            sqlite3_commit_hook(db, rejectingCommitHook, nil)
        }
        defer {
            if injectFailure { sqlite3_commit_hook(db, nil, nil) }
        }
        do throws(SQLiteError) {
            try execInternal("COMMIT")
        } catch {
            if sqlite3_get_autocommit(db) == 0 {
                rollbackIfNeeded()
                throw error
            }
            throw .commitOutcomeUnknown(error)
        }
    }

    var isAutocommit: Bool {
        guard let db else { return true }
        return sqlite3_get_autocommit(db) != 0
    }

    /// Rolls back an open transaction, ignoring errors (used on failure paths).
    func rollbackIfNeeded() {
        guard let db, sqlite3_get_autocommit(db) == 0 else { return }
        allowTransactionControl = true
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        allowTransactionControl = false
    }

    // MARK: User statements

    /// Prepares exactly one statement, from the cache if possible.
    func prepare(_ sql: String, cached: Bool) throws(SQLiteError) -> (statement: OpaquePointer, isCached: Bool) {
        let db = try handle()
        if cached, let statement = cache.lookup(sql) {
            return (statement, true)
        }
        var statement: OpaquePointer?
        var trailingSQL = false
        let flags = UInt32(cached && cache.capacity > 0 ? SQLITE_PREPARE_PERSISTENT : 0)
        let rc = sql.withCString { start -> Int32 in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v3(db, start, -1, flags, &statement, &tail)
            if rc == SQLITE_OK, var cursor = tail {
                while cursor.pointee != 0 {
                    let byte = UInt8(bitPattern: cursor.pointee)
                    if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x3B {
                        trailingSQL = true
                        break
                    }
                    cursor += 1
                }
            }
            return rc
        }
        guard rc == SQLITE_OK else { throw error(rc) }
        guard let statement else { throw .invalidArgument("the SQL contains no statement") }
        if trailingSQL {
            sqlite3_finalize(statement)
            throw .invalidArgument("expected exactly one SQL statement; use executeScript for several")
        }
        if cached, cache.insert(sql, statement) {
            return (statement, true)
        }
        return (statement, false)
    }

    func release(_ statement: OpaquePointer, isCached: Bool) {
        if isCached {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            sqlite3_finalize(statement)
        }
    }

    func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws(SQLiteError) {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard values.count == expected else {
            throw .invalidArgument("the statement has \(expected) parameters but \(values.count) values were bound")
        }
        let hardCap = configuration.limits.hardMaxResultBytes
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .integer(let v):
                rc = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                rc = sqlite3_bind_double(statement, index, v)
            case .text(let s):
                let count = s.utf8.count
                guard count <= hardCap else { throw .resultTooLarge(limit: hardCap) }
                rc = s.withCString { sqlite3_bind_text(statement, index, $0, Int32(count), transient) }
            case .blob(let bytes):
                guard bytes.count <= hardCap else { throw .resultTooLarge(limit: hardCap) }
                if bytes.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = bytes.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                    }
                }
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
    }

    static func columnValue(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob([]) }
            return .blob(Array(UnsafeRawBufferPointer(start: pointer, count: count)))
        default:
            return .null
        }
    }

    /// Steps a bound statement to completion within the given row and byte limits.
    func collectRows(_ statement: OpaquePointer, maxRows: Int, maxBytes: Int) throws(SQLiteError) -> [SQLiteRow] {
        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "")
        }
        var rows: [SQLiteRow] = []
        var totalBytes = 0
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            guard rows.count < maxRows else { throw .rowLimitExceeded(limit: maxRows) }
            var values: [SQLiteValue] = []
            values.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                let type = sqlite3_column_type(statement, index)
                let size: Int
                switch type {
                case SQLITE_TEXT, SQLITE_BLOB: size = Int(sqlite3_column_bytes(statement, index))
                case SQLITE_INTEGER, SQLITE_FLOAT: size = 8
                default: size = 0
                }
                totalBytes += size
                guard totalBytes <= maxBytes else { throw .resultTooLarge(limit: maxBytes) }
                values.append(Self.columnValue(statement, index))
            }
            rows.append(SQLiteRow(columnNames: names, values: values))
        }
        return rows
    }
}

private func rejectingCommitHook(_: UnsafeMutableRawPointer?) -> Int32 {
    1
}

private func busyCallback(_ context: UnsafeMutableRawPointer?, _ attempt: Int32) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<SQLiteConnectionCore>.fromOpaque(context).takeUnretainedValue().onBusy(attempt: attempt)
}

private func authorizerCallback(
    _ context: UnsafeMutableRawPointer?,
    _ action: Int32,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?
) -> Int32 {
    guard let context else { return SQLITE_OK }
    return Unmanaged<SQLiteConnectionCore>.fromOpaque(context).takeUnretainedValue().authorize(action: action)
}

/// One connection: a SQLite handle plus the dedicated thread that uses it.
final class SQLiteConnection: Sendable {
    let core: SQLiteConnectionCore
    let worker: SQLiteWorkerThread

    init(role: ConnectionRole, configuration: SQLiteConfiguration) throws(SQLiteError) {
        core = SQLiteConnectionCore(role: role, configuration: configuration)
        worker = try SQLiteWorkerThread(name: role.threadName)
    }

    deinit {
        // A database that was not closed: close the handle on its own thread, then join.
        let core = self.core
        worker.enqueue { core.close() }
        worker.stopAndJoin()
    }

    /// Runs `body` on this connection's thread and waits for it without blocking the
    /// cooperative pool. Task cancellation sets the job's flag and calls
    /// `sqlite3_interrupt` if the job is running.
    func run<T: Sendable>(
        _ body: @escaping @Sendable (SQLiteConnectionCore) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let token = SQLiteJobToken()
        let core = self.core
        let result: Result<T, SQLiteError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, SQLiteError>, Never>) in
                let accepted = worker.enqueue {
                    core.interrupt.withLock { $0.current = token }
                    core.activeToken = token
                    let outcome: Result<T, SQLiteError>
                    if token.isCancelled {
                        outcome = .failure(.interrupted)
                    } else {
                        outcome = Result { () throws(SQLiteError) -> T in try body(core) }
                    }
                    core.activeToken = nil
                    core.interrupt.withLock { $0.current = nil }
                    continuation.resume(returning: outcome)
                }
                if !accepted {
                    continuation.resume(returning: .failure(.closed))
                }
            }
        } onCancel: {
            token.cancel()
            core.interrupt.withLock { state in
                if state.current === token, let handle = state.handle {
                    sqlite3_interrupt(handle.pointer)
                }
            }
        }
        return try result.get()
    }

    /// Closes the handle on the worker thread and joins the thread.
    func shutdown() async {
        let core = self.core
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let accepted = worker.enqueue {
                core.close()
                continuation.resume()
            }
            if !accepted { continuation.resume() }
        }
        worker.stopAndJoin()
    }
}
