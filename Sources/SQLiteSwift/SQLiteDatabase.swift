// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif

/// What a ``SQLiteDatabase/writeOrRollback(limits:_:)`` closure decided.
///
/// The cases are complete; no case will be added.
public enum SQLiteTransactionOutcome<Value: Sendable>: Sendable {
    /// Commit the transaction and return the value.
    case commit(Value)
    /// Roll the transaction back and return the value.
    case rollback(Value)
}

/// The mode of a WAL checkpoint (`sqlite3_wal_checkpoint_v2`). SQLite has exactly these
/// four modes.
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
///   back and throws ``SQLiteError/Code/interrupted``.
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
    private let lifecycle = SQLiteLocked(Lifecycle.open)

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
    /// With a ``SQLiteConfiguration/fileIdentity``, an existing file must carry it, or
    /// opening fails with ``SQLiteError/Code/fileIdentityMismatch`` before anything is
    /// written.
    ///
    /// A database whose `user_version` is newer than `migrations.count` is refused with
    /// ``SQLiteError/Code/schemaTooNew`` before anything
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
                let identity = try core.inspectFileIdentity()
                _ = try core.checkSchemaVersion(supported: migrations.count)
                try core.applyFileIdentity(identity)
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
    /// was synced; on Apple platforms with `F_FULLFSYNC` by default). If `body` throws,
    /// or the task is cancelled before the commit, the transaction is rolled back and
    /// the error is thrown.
    ///
    /// If `COMMIT` itself fails after the transaction has ended, the call throws
    /// ``SQLiteError/Code/commitOutcomeUnknown``: the write may or may not be durable.
    /// Every other thrown error means the transaction was not committed.
    ///
    /// - Parameters:
    ///   - limits: Time and instruction bounds for this call. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    ///   - body: The transaction's work. It runs on the writer connection's thread.
    @discardableResult
    public func write<T: Sendable>(
        limits: SQLiteOperationLimits? = nil,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        try await writeOrRollback(limits: limits) { (transaction) throws(SQLiteError) in
            .commit(try body(transaction))
        }
    }

    /// Runs `body` in a write transaction that the closure commits or rolls back.
    ///
    /// Use it to keep a domain outcome (for example a compare-and-set conflict) as a
    /// value while discarding the transaction's other changes.
    ///
    /// - Parameters:
    ///   - limits: Time and instruction bounds for this call. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    ///   - body: The transaction's work and its decision.
    @discardableResult
    public func writeOrRollback<T: Sendable>(
        limits: SQLiteOperationLimits? = nil,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> SQLiteTransactionOutcome<T>
    ) async throws(SQLiteError) -> T {
        let token = try makeToken(limits)
        let slot = try await writerPool.acquire(deadline: token.deadline)
        defer { writerPool.release(slot) }
        return try await writer.run(token: token) { (core) throws(SQLiteError) -> T in
            try core.execInternal("BEGIN IMMEDIATE")
            let transaction = SQLiteTransaction(core: core, kind: .write)
            do throws(SQLiteError) {
                let outcome = try body(transaction)
                transaction.invalidate()
                switch outcome {
                case .commit(let value):
                    try core.checkStop()
                    try core.commitTransaction()
                    return value
                case .rollback(let value):
                    try core.execFinishing("ROLLBACK")
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
    /// ``SQLiteError/Code/readOnly``.
    ///
    /// - Parameters:
    ///   - limits: Time and instruction bounds for this call. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    ///   - body: The transaction's work. It runs on a reader connection's thread.
    @discardableResult
    public func read<T: Sendable>(
        limits: SQLiteOperationLimits? = nil,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let token = try makeToken(limits)
        let (pool, connections) = readerPool.map { ($0, readers) } ?? (writerPool, [writer])
        let slot = try await pool.acquire(deadline: token.deadline)
        defer { pool.release(slot) }
        return try await connections[slot].run(token: token) { (core) throws(SQLiteError) -> T in
            try core.execInternal("BEGIN DEFERRED")
            let transaction = SQLiteTransaction(core: core, kind: .read)
            defer { transaction.invalidate() }
            do throws(SQLiteError) {
                let value = try body(transaction)
                try core.execFinishing("COMMIT")
                return value
            } catch {
                core.rollbackIfNeeded()
                throw error
            }
        }
    }

    /// A job token carrying the call's deadline and instruction budget.
    private func makeToken(_ limits: SQLiteOperationLimits?) throws(SQLiteError) -> SQLiteJobToken {
        let limits = limits ?? configuration.operationLimits
        try limits.validate()
        return SQLiteJobToken(
            deadline: limits.timeout.map { ContinuousClock.now + $0 },
            maxInstructions: limits.maxInstructions)
    }

    // MARK: Maintenance

    /// Runs a WAL checkpoint on the writer connection.
    ///
    /// `.truncate` also truncates the WAL file to zero bytes when it succeeds fully.
    /// Readers holding old snapshots can make `.full`, `.restart` and `.truncate`
    /// wait up to the busy timeout and then throw ``SQLiteError/Code/busy``.
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

    /// The settings in force on the writer connection, read back from SQLite.
    public func effectiveSettings() async throws(SQLiteError) -> SQLiteEffectiveSettings {
        let slot = try await writerPool.acquire()
        defer { writerPool.release(slot) }
        return try await writer.run { (core) throws(SQLiteError) in try core.effectiveSettings() }
    }

    /// The database's current `PRAGMA user_version`.
    public func schemaVersion() async throws(SQLiteError) -> Int {
        try await read { (transaction) throws(SQLiteError) in try transaction.userVersion() }
    }

    /// Closes all connections and joins their threads.
    ///
    /// Operations already running finish first; operations waiting for a connection
    /// and all later calls throw ``SQLiteError/Code/closed``. Calling `close()` again waits
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

    /// Whether ``close()`` has started.
    var isClosing: Bool {
        lifecycle.withLock { state in
            if case .open = state { return false }
            return true
        }
    }

    // MARK: Diagnostics (internal; used by tests)

    var allWorkersExited: Bool {
        writer.worker.hasExited && readers.allSatisfy { $0.worker.hasExited }
    }
}

extension SQLiteConnectionCore {
    /// Reads a pragma back and throws ``SQLiteError/Code/settingMismatch``
    /// if it isn't the expected value.
    func verifyPragma(_ name: String, expected: SQLiteValue) throws(SQLiteError) {
        let actual = try scalarInternal("PRAGMA \(name)")
        let matches: Bool
        switch (actual, expected) {
        case (.text(let a), .text(let e)): matches = a.lowercased() == e.lowercased()
        default: matches = actual == expected
        }
        guard matches else {
            throw .settingMismatch(setting: name, expected: expected.description, actual: actual.description)
        }
    }

    var synchronousLevel: SQLiteValue {
        .integer(Int64(configuration.synchronous.level))
    }

    func configureWriter() throws(SQLiteError) {
        // SQLite silently opens a non-writable file read-only; fail at open instead of
        // at the first write, so hosts can tell "not writable" from "busy".
        if sqlite3_db_readonly(try handle(), "main") == 1 {
            throw .readOnly("the database file is not writable: \(path)")
        }
        if case .file = configuration.storage {
            try execInternal("PRAGMA journal_mode = WAL")
            try verifyPragma("journal_mode", expected: .text("wal"))
        }
        try execInternal("PRAGMA synchronous = \(configuration.synchronous.pragmaValue)")
        try execInternal("PRAGMA foreign_keys = \(configuration.foreignKeys ? "ON" : "OFF")")
        try execInternal("PRAGMA trusted_schema = OFF")
        try execInternal("PRAGMA wal_autocheckpoint = \(configuration.walAutoCheckpointPages)")
        try verifyPragma("synchronous", expected: synchronousLevel)
        try verifyPragma("foreign_keys", expected: .integer(configuration.foreignKeys ? 1 : 0))
        try verifyPragma("trusted_schema", expected: .integer(0))
        try configureFullFSync()
    }

    func configureReader() throws(SQLiteError) {
        try execInternal("PRAGMA query_only = ON")
        try execInternal("PRAGMA synchronous = \(configuration.synchronous.pragmaValue)")
        try execInternal("PRAGMA trusted_schema = OFF")
        try verifyPragma("query_only", expected: .integer(1))
        try verifyPragma("synchronous", expected: synchronousLevel)
        try verifyPragma("trusted_schema", expected: .integer(0))
        try configureFullFSync()
    }

    /// Applies and verifies `fullfsync`/`checkpoint_fullfsync` on Apple platforms.
    func configureFullFSync() throws(SQLiteError) {
        #if canImport(Darwin)
        let value = configuration.appleFullFSync ? "ON" : "OFF"
        let expected: SQLiteValue = .integer(configuration.appleFullFSync ? 1 : 0)
        try execInternal("PRAGMA fullfsync = \(value)")
        try execInternal("PRAGMA checkpoint_fullfsync = \(value)")
        try verifyPragma("fullfsync", expected: expected)
        try verifyPragma("checkpoint_fullfsync", expected: expected)
        #endif
    }

    func effectiveSettings() throws(SQLiteError) -> SQLiteEffectiveSettings {
        func integer(_ name: String) throws(SQLiteError) -> Int {
            guard case .integer(let v) = try scalarInternal("PRAGMA \(name)") else { return -1 }
            return Int(v)
        }
        guard case .text(let journal) = try scalarInternal("PRAGMA journal_mode") else {
            throw .misuse("journal_mode returned no text")
        }
        var compileOptions: [String] = []
        let db = try handle()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "PRAGMA compile_options", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if case .text(let option) = Self.columnValue(statement, 0) { compileOptions.append(option) }
        }
        return SQLiteEffectiveSettings(
            journalMode: journal.lowercased(),
            synchronous: try integer("synchronous"),
            foreignKeys: try integer("foreign_keys") == 1,
            trustedSchema: try integer("trusted_schema") == 1,
            fullFSync: try integer("fullfsync") == 1,
            checkpointFullFSync: try integer("checkpoint_fullfsync") == 1,
            busyTimeout: configuration.busyTimeout,
            sqliteVersion: String(cString: sqlite3_libversion()),
            sqliteSourceID: String(cString: sqlite3_sourceid()),
            applicationID: Int32(truncatingIfNeeded: try integerPragma("application_id")),
            pageSize: Int(try integerPragma("page_size")),
            autoVacuum: SQLiteAutoVacuum(rawValue: Int(try integerPragma("auto_vacuum"))) ?? .none,
            mmapSize: Int(try integerPragma("mmap_size")),
            maxLength: Int(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1)),
            compileOptions: compileOptions)
    }
}

/// The settings actually in force on the writer connection, read back from SQLite.
public struct SQLiteEffectiveSettings: Sendable, Hashable {
    /// `PRAGMA journal_mode`, lowercased (`wal`, or `memory` for in-memory databases).
    public var journalMode: String
    /// `PRAGMA synchronous`: 1 = NORMAL, 2 = FULL, 3 = EXTRA.
    public var synchronous: Int
    public var foreignKeys: Bool
    public var trustedSchema: Bool
    /// `PRAGMA fullfsync` (only meaningful on Apple platforms).
    public var fullFSync: Bool
    /// `PRAGMA checkpoint_fullfsync` (only meaningful on Apple platforms).
    public var checkpointFullFSync: Bool
    /// The configured busy timeout (enforced by SQLiteSwift's busy handler).
    public var busyTimeout: Duration
    /// `sqlite3_libversion()` of the engine in use.
    public var sqliteVersion: String
    /// `sqlite3_sourceid()` of the engine in use.
    public var sqliteSourceID: String
    /// `PRAGMA application_id` (0 if the file has none).
    public var applicationID: Int32
    /// `PRAGMA page_size` in bytes.
    public var pageSize: Int
    /// `PRAGMA auto_vacuum`.
    public var autoVacuum: SQLiteAutoVacuum
    /// `PRAGMA mmap_size` in bytes (0 means memory-mapped I/O is off).
    public var mmapSize: Int
    /// `SQLITE_LIMIT_LENGTH`: the largest string, BLOB or row SQLite accepts
    /// (``SQLiteLimits/hardMaxResultBytes``).
    public var maxLength: Int
    /// `PRAGMA compile_options` of the engine in use, without the `SQLITE_` prefix.
    public var compileOptions: [String]
}
