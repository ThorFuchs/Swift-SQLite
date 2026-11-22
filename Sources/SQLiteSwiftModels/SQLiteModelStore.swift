// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// Managed writes over a database, with a stream of what they committed.
///
/// Write records through the store (``writeRecords(_:origin:limits:)``, or a
/// `SQLiteModelContext` made from it) and subscribe to their committed changes
/// with ``subscribe(bufferSize:limits:_:)``. Create one store per database and
/// share it.
///
/// **Scope of the stream.** It reports batches written through this store in this
/// process. Raw SQL, `SQLiteDatabase.writeRecords(_:limits:)` called
/// on the database directly, other `SQLiteDatabase` instances and other processes
/// produce no events.
///
/// The database needs the store's tables: include
/// ``SQLiteModelSchema/migration(version:name:)`` in its migrations.
///
/// **Resuming after a restart.** With a ``ChangeLog``, every committed batch is also
/// written to a bounded log in its own transaction, so a consumer can continue from
/// the last sequence it processed with ``subscribe(after:bufferSize:limits:)``.
public final class SQLiteModelStore: Sendable {
    /// A durable, bounded log of committed batches.
    public struct ChangeLog: Sendable, Hashable {
        /// How many of the most recent batches the log keeps. Older ones are deleted
        /// in the same transaction that adds a new one.
        public var retainedBatches: Int

        /// Keeps the most recent `batches` batches (default 10,000).
        public static func retain(batches: Int = 10_000) -> ChangeLog {
            ChangeLog(retainedBatches: batches)
        }
    }

    /// The database the store writes to.
    public let database: SQLiteDatabase
    /// The change log, or `nil` if the store keeps none.
    public let changeLog: ChangeLog?
    let hub = SQLiteChangeHub()
    /// Managed writes run one at a time, so batches are published in commit order.
    private let turn = SQLiteAsyncTurn()

    /// - Parameters:
    ///   - database: The database. Its migrations include
    ///     ``SQLiteModelSchema/migration(version:name:)`` and, with a change log,
    ///     ``SQLiteModelSchema/changeLogMigration(version:name:)``.
    ///   - changeLog: Keep a durable log for resumable subscriptions, or `nil`.
    public init(database: SQLiteDatabase, changeLog: ChangeLog?) {
        self.database = database
        self.changeLog = changeLog
    }

    /// A store without a change log. Its migrations include
    /// ``SQLiteModelSchema/migration(version:name:)``.
    public convenience init(database: SQLiteDatabase) {
        self.init(database: database, changeLog: nil)
    }

    /// Runs `writes` in order in one transaction, all or nothing, like
    /// `SQLiteDatabase.writeRecords(_:limits:)`, and publishes the
    /// committed batch.
    ///
    /// - Parameters:
    ///   - writes: The writes, in the order they run.
    ///   - origin: Passed along in the published change.
    ///   - limits: Time and instruction bounds for the transaction. `nil` uses the
    ///     database's default.
    @discardableResult
    public func writeRecords(
        _ writes: [SQLiteRecordWrite], origin: SQLiteChangeOrigin? = nil, limits: SQLiteOperationLimits? = nil
    ) async throws(SQLiteError) -> SQLiteRecordBatchOutcome {
        guard !writes.isEmpty else { return .committed([]) }
        return try await managedWrite(origin: origin, limits: limits) { (tx) throws(SQLiteError) in
            var reports: [SQLiteRecordWriteReport] = []
            for (index, write) in writes.enumerated() {
                let report = try write.run(at: index, in: tx)
                guard report.isApplied else { return .rollback((.rolledBack(failure: report), [])) }
                reports.append(report)
            }
            return .commit((.committed(reports), reports))
        }
    }

    /// Runs a managed write transaction.
    ///
    /// `body` commits with its result and the reports of the writes it applied, or
    /// rolls back. A commit increments the store's sequence in the same transaction
    /// and is published after the write returns. A commit whose outcome is unknown
    /// publishes nothing and sends ``SQLiteChangeEvent/resyncRequired`` to every
    /// subscriber.
    package func managedWrite<T: Sendable>(
        origin: SQLiteChangeOrigin?, limits: SQLiteOperationLimits? = nil,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError)
            -> SQLiteTransactionOutcome<(T, [SQLiteRecordWriteReport])>
    ) async throws(SQLiteError) -> T {
        if let changeLog, changeLog.retainedBatches < 1 {
            throw .invalidConfiguration("ChangeLog.retainedBatches must be at least 1")
        }
        await turn.begin()
        defer { turn.end() }
        let table = SQLiteModelSchema.sequenceTable
        let changeLog = self.changeLog
        let result: (T, SQLiteCommittedChange?)
        do throws(SQLiteError) {
            result = try await database.writeOrRollback(limits: limits) { (tx) throws(SQLiteError) in
                switch try body(tx) {
                case .rollback(let value):
                    return .rollback((value.0, nil))
                case .commit(let value):
                    guard let row = try tx.queryOne(
                        "UPDATE \(table) SET value = value + 1 WHERE id = 1 RETURNING value")
                    else {
                        throw .schemaMismatch(setting: table, expected: "one row", actual: "missing")
                    }
                    let change = SQLiteCommittedChange(
                        sequence: try row.integer(0), origin: origin,
                        changes: value.1.compactMap(SQLiteRecordChange.init))
                    if let changeLog { try Self.log(change, in: tx, retaining: changeLog.retainedBatches) }
                    return .commit((value.0, change))
                }
            }
        } catch {
            if error.code == .commitOutcomeUnknown { hub.resyncAll() }
            throw error
        }
        if let change = result.1 { hub.publish(change) }
        return result.0
    }

    /// Reads a snapshot and subscribes to the batches committed after it.
    ///
    /// The subscription is registered before `snapshot` runs, and `snapshot` runs in
    /// a read transaction that also reads the store's sequence. Batches already in
    /// the snapshot are dropped; every later one is delivered. Nothing is lost
    /// between the snapshot and the first event.
    ///
    /// - Parameters:
    ///   - bufferSize: How many undelivered events the subscription holds. One more
    ///     replaces them with ``SQLiteChangeEvent/resyncRequired``.
    ///   - limits: Time and instruction bounds for the snapshot read.
    ///   - snapshot: Reads the state the events apply to.
    public func subscribe<T: Sendable>(
        bufferSize: Int = 1024, limits: SQLiteOperationLimits? = nil,
        _ snapshot: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> (snapshot: T, changes: SQLiteChangeSubscription) {
        guard bufferSize >= 1 else { throw .invalidArgument("bufferSize must be at least 1") }
        let id = try hub.add(capacity: bufferSize)
        let subscription = SQLiteChangeSubscription(id: id, hub: hub)
        let table = SQLiteModelSchema.sequenceTable
        let (value, watermark) = try await database.read(limits: limits) { (tx) throws(SQLiteError) in
            let value = try snapshot(tx)
            guard let row = try tx.queryOne("SELECT value FROM \(table) WHERE id = 1") else {
                throw .schemaMismatch(setting: table, expected: "one row", actual: "missing")
            }
            return (value, try row.integer(0))
        }
        hub.setWatermark(watermark, for: id)
        return (value, subscription)
    }

    /// Continues a stream after `sequence`, the last batch the consumer processed,
    /// for example after a restart.
    ///
    /// The store must keep a ``ChangeLog``. The subscription first delivers the
    /// logged batches after `sequence`, in order, then the live ones; nothing is lost
    /// or delivered twice between the two. It delivers only
    /// ``SQLiteChangeEvent/resyncRequired`` (and ends) when it can't continue
    /// exactly: the log no longer reaches back to `sequence`, `sequence` is ahead of
    /// the store (for example a restored backup), or the missed batches don't fit the
    /// buffer. Then read a new snapshot with ``subscribe(bufferSize:limits:_:)``.
    ///
    /// - Parameters:
    ///   - sequence: The last processed ``SQLiteCommittedChange/sequence``; 0 for
    ///     "from the beginning of the log".
    ///   - bufferSize: How many undelivered events the subscription holds, the
    ///     missed batches included.
    ///   - limits: Time and instruction bounds for reading the log.
    public func subscribe(
        after sequence: Int64, bufferSize: Int = 1024, limits: SQLiteOperationLimits? = nil
    ) async throws(SQLiteError) -> SQLiteChangeSubscription {
        guard changeLog != nil else {
            throw .invalidConfiguration("a resumable subscription needs a store with a ChangeLog")
        }
        guard bufferSize >= 1 else { throw .invalidArgument("bufferSize must be at least 1") }
        guard sequence >= 0 else { throw .invalidArgument("sequence must not be negative") }
        let id = try hub.add(capacity: bufferSize)
        let subscription = SQLiteChangeSubscription(id: id, hub: hub)
        let history = try await database.read(limits: limits) { (tx) throws(SQLiteError) -> (Int64, [SQLiteCommittedChange]?) in
            try Self.history(after: sequence, maxBatches: bufferSize, in: tx)
        }
        if let batches = history.1 {
            hub.prime(batches, watermark: history.0, for: id)
        } else {
            hub.resync(id)
        }
        return subscription
    }

    /// The store's current sequence: how many batches it has committed to this file.
    public func currentSequence() async throws(SQLiteError) -> Int64 {
        let table = SQLiteModelSchema.sequenceTable
        return try await database.read { (tx) throws(SQLiteError) in
            guard let row = try tx.queryOne("SELECT value FROM \(table) WHERE id = 1") else {
                throw .schemaMismatch(setting: table, expected: "one row", actual: "missing")
            }
            return try row.integer(0)
        }
    }

    /// Ends every subscription and closes the database.
    public func close() async {
        hub.close()
        await database.close()
    }
}

/// A first-in, first-out turn for async callers.
final class SQLiteAsyncTurn: Sendable {
    private struct State: Sendable {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = SQLiteLocked(State())

    func begin() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.busy {
                    state.waiters.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if ready { continuation.resume() }
        }
    }

    func end() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.busy = false
                return nil
            }
            return state.waiters.removeFirst()  // the turn passes on; stays busy
        }
        next?.resume()
    }
}

// MARK: Change log

extension SQLiteModelStore {
    private static let batches = SQLiteModelSchema.changeBatchesTable
    private static let changes = SQLiteModelSchema.changesTable

    /// Writes `change` to the log and deletes batches beyond the retention.
    static func log(_ change: SQLiteCommittedChange, in tx: SQLiteTransaction, retaining: Int) throws(SQLiteError) {
        let origin: SQLiteRawValue = change.origin.map { .blob($0.value) } ?? .null
        try tx.executeRaw("INSERT INTO \(batches) (sequence, origin) VALUES (?, ?)", [.integer(change.sequence), origin])
        for (position, record) in change.changes.enumerated() {
            let kind: Int64 = switch record.kind {
            case .inserted: 0
            case .updated: 1
            case .deleted: 2
            }
            try tx.executeRaw("""
                INSERT INTO \(changes) (sequence, position, table_name, record_key, kind, revision, incarnation)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.integer(change.sequence), .integer(Int64(position)), .text(Array(record.table.utf8)), record.key,
                      .integer(kind), record.version.map { .integer($0.revision) } ?? .null,
                      record.version.map { .blob($0.incarnation) } ?? .null])
        }
        let oldestKept = change.sequence - Int64(retaining) + 1
        if oldestKept > 1 {
            try tx.executeRaw("DELETE FROM \(changes) WHERE sequence < ?", [.integer(oldestKept)])
            try tx.executeRaw("DELETE FROM \(batches) WHERE sequence < ?", [.integer(oldestKept)])
        }
    }

    /// The current sequence and the logged batches after `sequence`, or `nil` for
    /// the batches when the log can't continue exactly from there.
    static func history(
        after sequence: Int64, maxBatches: Int, in tx: SQLiteTransaction
    ) throws(SQLiteError) -> (Int64, [SQLiteCommittedChange]?) {
        let sequenceTable = SQLiteModelSchema.sequenceTable
        guard let current = try tx.queryOne("SELECT value FROM \(sequenceTable) WHERE id = 1") else {
            throw .schemaMismatch(setting: sequenceTable, expected: "one row", actual: "missing")
        }
        let latest = try current.integer(0)
        if sequence > latest { return (latest, nil) }  // ahead of the store
        if sequence == latest { return (latest, []) }
        let missing = latest - sequence
        if missing > Int64(maxBatches) { return (latest, nil) }  // doesn't fit the buffer
        let counted = try tx.queryRaw(
            "SELECT count(*), min(sequence) FROM \(batches) WHERE sequence > ?", [.integer(sequence)])
        guard case .integer(let count) = counted.first?[0], count == missing,
              case .integer(let first) = counted.first?[1], first == sequence + 1
        else { return (latest, nil) }  // the log no longer reaches back far enough

        var result: [SQLiteCommittedChange] = []
        let batchRows = try tx.queryRaw(
            "SELECT sequence, origin FROM \(batches) WHERE sequence > ? ORDER BY sequence",
            [.integer(sequence)], limits: SQLiteQueryLimits(maxRows: max(1, Int(missing))))
        var changeRows: [SQLiteRawRow] = []
        do throws(SQLiteError) {
            changeRows = try tx.queryRaw("""
                SELECT sequence, table_name, record_key, kind, revision, incarnation FROM \(changes)
                WHERE sequence > ? ORDER BY sequence, position
                """, [.integer(sequence)])
        } catch where error.code == .rowLimitExceeded || error.code == .resultTooLarge {
            return (latest, nil)  // too much to replay in one read; take a snapshot instead
        }
        var byBatch: [Int64: [SQLiteRecordChange]] = [:]
        for row in changeRows {
            guard case .integer(let seq) = row[0], case .text(let table) = row[1], case .integer(let kind) = row[3] else {
                throw .invalidStoredValue(column: changes, reason: "malformed change row")
            }
            var version: SQLiteRecordVersion?
            if case .integer(let revision) = row[4], case .blob(let incarnation) = row[5] {
                version = try SQLiteRecordVersion(revision: revision, incarnation: incarnation)
            }
            let recordKind: SQLiteRecordChange.Kind = kind == 0 ? .inserted : kind == 1 ? .updated : .deleted
            byBatch[seq, default: []].append(SQLiteRecordChange(
                table: String(decoding: table, as: UTF8.self), key: row[2], kind: recordKind, version: version))
        }
        for row in batchRows {
            guard case .integer(let seq) = row[0] else {
                throw .invalidStoredValue(column: batches, reason: "malformed batch row")
            }
            let origin: SQLiteChangeOrigin? = if case .blob(let bytes) = row[1] { SQLiteChangeOrigin(stored: bytes) } else { nil }
            result.append(SQLiteCommittedChange(sequence: seq, origin: origin, changes: byBatch[seq] ?? []))
        }
        return (latest, result)
    }
}
