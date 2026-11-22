// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

extension SQLiteModelStore {
    /// The records matching `filter`, as an asynchronous sequence of result lists that
    /// follows the store's committed changes. No main actor: suited to servers, for
    /// example to push updates over server-sent events or a WebSocket.
    ///
    /// ```swift
    /// for try await drafts in store.records(Article.self, where: .equals("status", "draft")) {
    ///     try await send(drafts.map(\.value))
    /// }
    /// ```
    ///
    /// The first element is the current result. After that, a new result follows each
    /// committed batch that touches the record's table:
    ///
    /// - **Coalesced.** A burst of batches that arrive while the consumer is busy leads
    ///   to one new read, which already includes all of them.
    /// - **Only real changes.** A read whose result equals the last one is not emitted
    ///   (for example a change outside the filter).
    /// - **Self-healing.** If the stream asks for a resync (a full buffer, or an unknown
    ///   commit), the next element is a fresh read.
    ///
    /// Results are in key order and never truncated: more rows than `limits` allow throw
    /// `SQLiteError.Code.rowLimitExceeded`. The sequence ends when the iterating task is
    /// cancelled or the store closes. Only batches written through this store are seen.
    ///
    /// - Parameters:
    ///   - type: The record type.
    ///   - filter: Which rows to include; `nil` for all.
    ///   - limits: Row and byte limits for each read.
    ///   - bufferSize: How many undelivered change events the underlying subscription
    ///     holds before it asks for a resync.
    public func records<Record: SQLiteRecord>(
        _ type: Record.Type, where filter: SQLitePredicate? = nil, limits: SQLiteQueryLimits? = nil,
        bufferSize: Int = 1024
    ) -> SQLiteLiveRecords<Record> {
        SQLiteLiveRecords(store: self, filter: filter, limits: limits, bufferSize: bufferSize)
    }
}

/// The asynchronous sequence ``SQLiteModelStore/records(_:where:limits:bufferSize:)``
/// returns. Each element is the full, current result.
public struct SQLiteLiveRecords<Record: SQLiteRecord>: AsyncSequence, Sendable {
    public typealias Element = [SQLiteRecordSnapshot<Record>]
    public typealias Failure = SQLiteError

    let store: SQLiteModelStore
    let filter: SQLitePredicate?
    let limits: SQLiteQueryLimits?
    let bufferSize: Int

    public func makeAsyncIterator() -> Iterator {
        Iterator(sequence: self)
    }

    /// Iterate it from one task.
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = [SQLiteRecordSnapshot<Record>]
        public typealias Failure = SQLiteError

        private let sequence: SQLiteLiveRecords
        private var changes: SQLiteChangeSubscription?
        private var events: SQLiteChangeSubscription.Iterator?
        private var last: Element?
        /// The store sequence the last read saw; events up to it are already included.
        private var seen: Int64 = 0
        private var finished = false

        init(sequence: SQLiteLiveRecords) {
            self.sequence = sequence
        }

        public mutating func next() async throws(SQLiteError) -> Element? {
            try await next(isolation: nil)
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws(SQLiteError) -> Element? {
            while !finished {
                if events == nil {
                    // Subscribe and read in one step, so nothing is lost in between.
                    let (rows, subscription) = try await Self.subscribe(sequence)
                    changes = subscription
                    events = subscription.makeAsyncIterator()
                    if let rows = try emit(rows) { return rows }
                    continue
                }
                guard let event = await events?.next(isolation: actor) else {
                    // The store closed or the task was cancelled.
                    finished = true
                    changes = nil
                    return nil
                }
                switch event {
                case .resyncRequired:
                    changes = nil
                    events = nil  // the next round reads a fresh snapshot
                case .committed(let change):
                    let table = Record.descriptor.table.name
                    guard change.sequence > seen, change.changes.contains(where: { $0.table == table }) else { continue }
                    let rows = try await Self.read(sequence)
                    if let rows = try emit(rows) { return rows }
                }
            }
            return nil
        }

        private mutating func emit(_ rows: (Int64, Element)) throws(SQLiteError) -> Element? {
            seen = Swift.max(seen, rows.0)
            guard rows.1 != last else { return nil }
            last = rows.1
            return rows.1
        }

        private static func subscribe(
            _ sequence: SQLiteLiveRecords
        ) async throws(SQLiteError) -> ((Int64, Element), SQLiteChangeSubscription) {
            let filter = sequence.filter, limits = sequence.limits
            let table = SQLiteModelSchema.sequenceTable
            let (result, subscription) = try await sequence.store.subscribe(bufferSize: sequence.bufferSize) {
                (tx) throws(SQLiteError) -> (Int64, Element) in
                (try Self.currentSequence(tx, table), try tx.fetchAll(Record.self, where: filter, limits: limits))
            }
            return (result, subscription)
        }

        private static func read(_ sequence: SQLiteLiveRecords) async throws(SQLiteError) -> (Int64, Element) {
            let filter = sequence.filter, limits = sequence.limits
            let table = SQLiteModelSchema.sequenceTable
            return try await sequence.store.database.read { (tx) throws(SQLiteError) -> (Int64, Element) in
                (try Self.currentSequence(tx, table), try tx.fetchAll(Record.self, where: filter, limits: limits))
            }
        }

        private static func currentSequence(_ tx: SQLiteTransaction, _ table: String) throws(SQLiteError) -> Int64 {
            guard let row = try tx.queryOne("SELECT value FROM \(table) WHERE id = 1") else {
                throw .schemaMismatch(setting: table, expected: "one row", actual: "missing")
            }
            return try row.integer(0)
        }
    }
}
