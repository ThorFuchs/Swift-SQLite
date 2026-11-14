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
public final class SQLiteModelStore: Sendable {
    /// The database the store writes to.
    public let database: SQLiteDatabase
    let hub = SQLiteChangeHub()
    /// Managed writes run one at a time, so batches are published in commit order.
    private let turn = SQLiteAsyncTurn()

    public init(database: SQLiteDatabase) {
        self.database = database
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
        await turn.begin()
        defer { turn.end() }
        let table = SQLiteModelSchema.sequenceTable
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
