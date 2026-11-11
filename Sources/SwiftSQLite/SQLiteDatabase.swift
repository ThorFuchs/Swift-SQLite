// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSwiftSQLite
#else
internal import SQLite3
#endif
import Synchronization

/// What a ``SQLiteDatabase/writeOrRollback(_:)`` closure decided.
public enum SQLiteTransactionOutcome<Value: Sendable>: Sendable {
    /// Commit the transaction and return the value.
    case commit(Value)
    /// Roll the transaction back and return the value.
    case rollback(Value)
}

/// The mode of a WAL checkpoint (`sqlite3_wal_checkpoint_v2`).
public enum SQLiteCheckpointMode: Sendable, Hashable {
    case passive, full, restart, truncate

    var rawValue: Int32 {
        switch self {
        case .passive: SQLITE_CHECKPOINT_PASSIVE
        case .full: SQLITE_CHECKPOINT_FULL
        case .restart: SQLITE_CHECKPOINT_RESTART
        case .truncate: SQLITE_CHECKPOINT_TRUNCATE
        }
    }
}

/// The result of a WAL checkpoint.
public struct SQLiteCheckpointResult: Sendable, Hashable {
    /// Frames in the WAL after the checkpoint (`-1` if the database isn't in WAL mode).
    public var walFrames: Int
    /// Frames copied back into the database (`-1` if not in WAL mode).
    public var checkpointedFrames: Int
}

/// A SQLite database with one writer connection and a bounded pool of reader
/// connections.
///
/// - Writes run in `BEGIN IMMEDIATE` transactions on the single writer connection and
///   return only after `COMMIT` succeeded.
/// - Reads run in deferred transactions on reader connections, each seeing one
///   consistent WAL snapshot. With `readerCount == 0`, reads use the writer connection.
/// - Each connection runs its SQLite calls on its own thread, never on the cooperative
///   thread pool. ``close()`` joins the threads.
/// - Task cancellation interrupts the running statement (`sqlite3_interrupt`), rolls
///   back and throws ``SQLiteError/interrupted``.
public final class SQLiteDatabase: Sendable {
    public let configuration: SQLiteConfiguration
    /// The schema version the migrations define (the number of migrations).
    public let supportedSchemaVersion: Int

    let writer: SQLiteConnection
    let readers: [SQLiteConnection]
    let writerPool: SQLiteSlotPool
    let readerPool: SQLiteSlotPool?

    private enum Lifecycle {
        case open
        case closing([CheckedContinuation<Void, Never>])
        case closed
    }
    private let lifecycle = Mutex(Lifecycle.open)

    private init(
        configuration: SQLiteConfiguration, supportedSchemaVersion: Int,
        writer: SQLiteConnection, readers: [SQLiteConnection]
    ) {
        self.configuration = configuration
        self.supportedSchemaVersion = supportedSchemaVersion
        self.writer = writer
        self.readers = readers
        self.writerPool = SQLiteSlotPool(capacity: 1)
        self.readerPool = readers.isEmpty ? nil : SQLiteSlotPool(capacity: readers.count)
    }

    // MARK: Opening

    /// Opens (or creates) a database, configures it and applies pending migrations.
    ///
    /// A database whose `user_version` is newer than `migrations.count` is refused with
    /// ``SQLiteError/schemaTooNew(databaseVersion:supportedVersion:)`` before anything
    /// is written to it, including the switch to WAL mode.
    ///
    /// - Parameters:
    ///   - configuration: Storage, pool size, durability and limits.
    ///   - migrations: Forward-only migrations numbered `1...n`. An empty list means
    ///     schema version 0.
    public static func open(
        _ configuration: SQLiteConfiguration, migrations: [SQLiteMigration]
    ) async throws(SQLiteError) -> SQLiteDatabase {
        try configuration.validate()
        try SQLiteMigration.validate(migrations)
        let writer = try SQLiteConnection(role: .writer, configuration: configuration)
        var readers: [SQLiteConnection] = []
        do throws(SQLiteError) {
            try await writer.run { (core) throws(SQLiteError) in
                try core.open()
                _ = try core.checkSchemaVersion(supported: migrations.count)
                try core.configureWriter()
                try core.migrate(migrations)
            }
            for index in 0..<configuration.readerCount {
                let reader = try SQLiteConnection(role: .reader(index), configuration: configuration)
                readers.append(reader)
                try await reader.run { (core) throws(SQLiteError) in
                    try core.open()
                    try core.configureReader()
                }
            }
        } catch {
            for reader in readers { await reader.shutdown() }
            await writer.shutdown()
            throw error
        }
        return SQLiteDatabase(
            configuration: configuration, supportedSchemaVersion: migrations.count,
            writer: writer, readers: readers)
    }

    // MARK: Transactions

    /// Runs `body` in a write transaction and commits it.
    ///
    /// Returns only after `COMMIT` succeeded (with `synchronous=FULL`, after the WAL
    /// was synced). If `body` throws, or the task is cancelled before the commit, the
    /// transaction is rolled back and the error is thrown.
    @discardableResult
    public func write<T: Sendable>(
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        try await writeOrRollback { (transaction) throws(SQLiteError) in
            .commit(try body(transaction))
        }
    }

    /// Runs `body` in a write transaction that the closure commits or rolls back.
    ///
    /// Use it to keep a domain outcome (for example a compare-and-set conflict) as a
    /// value while discarding the transaction's other changes.
    @discardableResult
    public func writeOrRollback<T: Sendable>(
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> SQLiteTransactionOutcome<T>
    ) async throws(SQLiteError) -> T {
        let slot = try await writerPool.acquire()
        defer { writerPool.release(slot) }
        return try await writer.run { (core) throws(SQLiteError) -> T in
            try core.execInternal("BEGIN IMMEDIATE")
            let transaction = SQLiteTransaction(core: core, kind: .write)
            do throws(SQLiteError) {
                let outcome = try body(transaction)
                transaction.invalidate()
                switch outcome {
                case .commit(let value):
                    try core.checkCancelled()
                    try core.execInternal("COMMIT")
                    return value
                case .rollback(let value):
                    try core.execInternal("ROLLBACK")
                    return value
                }
            } catch {
                transaction.invalidate()
                core.rollbackIfNeeded()
                throw error
            }
        }
    }

    /// Runs `body` in a read transaction.
    ///
    /// All statements in `body` see the same WAL snapshot. Statements that write throw
    /// ``SQLiteError/readOnly(_:)``.
    @discardableResult
    public func read<T: Sendable>(
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let (pool, connections) = readerPool.map { ($0, readers) } ?? (writerPool, [writer])
        let slot = try await pool.acquire()
        defer { pool.release(slot) }
        return try await connections[slot].run { (core) throws(SQLiteError) -> T in
            try core.execInternal("BEGIN DEFERRED")
            let transaction = SQLiteTransaction(core: core, kind: .read)
            defer { transaction.invalidate() }
            do throws(SQLiteError) {
                let value = try body(transaction)
                try core.execInternal("COMMIT")
                return value
            } catch {
                core.rollbackIfNeeded()
                throw error
            }
        }
    }

    // MARK: Maintenance

    /// Runs a WAL checkpoint on the writer connection.
    ///
    /// `.truncate` also truncates the WAL file to zero bytes when it succeeds fully.
    /// Readers holding old snapshots can make `.full`, `.restart` and `.truncate`
    /// wait up to the busy timeout and then throw ``SQLiteError/busy(_:)``.
    @discardableResult
    public func checkpoint(_ mode: SQLiteCheckpointMode = .passive) async throws(SQLiteError) -> SQLiteCheckpointResult {
        let slot = try await writerPool.acquire()
        defer { writerPool.release(slot) }
        return try await writer.run { (core) throws(SQLiteError) -> SQLiteCheckpointResult in
            let db = try core.handle()
            var log: Int32 = 0
            var checkpointed: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(db, nil, mode.rawValue, &log, &checkpointed)
            guard rc == SQLITE_OK else { throw core.error(rc) }
            return SQLiteCheckpointResult(walFrames: Int(log), checkpointedFrames: Int(checkpointed))
        }
    }

    /// The database's current `PRAGMA user_version`.
    public func schemaVersion() async throws(SQLiteError) -> Int {
        try await read { (transaction) throws(SQLiteError) in try transaction.userVersion() }
    }

    /// Closes all connections and joins their threads.
    ///
    /// Operations already running finish first; operations waiting for a connection
    /// and all later calls throw ``SQLiteError/closed``. Calling `close()` again waits
    /// for the first close to finish.
    public func close() async {
        enum Step { case perform, wait, done }
        let step: Step = lifecycle.withLock { state in
            switch state {
            case .open:
                state = .closing([])
                return .perform
            case .closing: return .wait
            case .closed: return .done
            }
        }
        switch step {
        case .done:
            return
        case .wait:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let finished = lifecycle.withLock { state -> Bool in
                    if case .closing(var waiters) = state {
                        waiters.append(continuation)
                        state = .closing(waiters)
                        return false
                    }
                    return true
                }
                if finished { continuation.resume() }
            }
        case .perform:
            if let readerPool { await readerPool.drain() }
            await writerPool.drain()
            // Close readers first so the writer, as the last connection, checkpoints
            // and removes the WAL.
            for reader in readers { await reader.shutdown() }
            await writer.shutdown()
            let waiters = lifecycle.withLock { state -> [CheckedContinuation<Void, Never>] in
                defer { state = .closed }
                if case .closing(let waiters) = state { return waiters }
                return []
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    // MARK: Diagnostics (internal; used by tests)

    var allWorkersExited: Bool {
        writer.worker.hasExited && readers.allSatisfy { $0.worker.hasExited }
    }
}

extension SQLiteConnectionCore {
    func configureWriter() throws(SQLiteError) {
        if case .file = configuration.storage {
            guard case .text(let mode) = try scalarInternal("PRAGMA journal_mode = WAL"),
                mode.lowercased() == "wal"
            else {
                throw .sqlite(SQLiteErrorDetails(
                    code: SQLiteResultCode(rawValue: SQLITE_ERROR), message: "could not enable WAL mode"))
            }
        }
        try execInternal("PRAGMA synchronous = \(configuration.synchronous.pragmaValue)")
        try execInternal("PRAGMA foreign_keys = \(configuration.foreignKeys ? "ON" : "OFF")")
        try execInternal("PRAGMA trusted_schema = OFF")
        try execInternal("PRAGMA wal_autocheckpoint = \(configuration.walAutoCheckpointPages)")
        #if canImport(Darwin)
        if configuration.appleFullFSync {
            try execInternal("PRAGMA fullfsync = ON")
            try execInternal("PRAGMA checkpoint_fullfsync = ON")
        }
        #endif
    }

    func configureReader() throws(SQLiteError) {
        try execInternal("PRAGMA query_only = ON")
        try execInternal("PRAGMA synchronous = \(configuration.synchronous.pragmaValue)")
        try execInternal("PRAGMA trusted_schema = OFF")
    }
}
