// SPDX-License-Identifier: Apache-2.0

import Observation
import SQLiteSwift
import SQLiteSwiftModels

/// The records of one table that match a filter, kept current while ``run(bufferSize:)``
/// runs.
///
/// ```swift
/// let drafts = SQLiteLiveQuery(Article.self, where: .equals("status", .text("draft")), store: store)
/// // SwiftUI: List(drafts.results, id: \.value.id) { … }.task { try? await drafts.run() }
/// ```
///
/// The query reads its results when it starts and again after every batch the
/// store commits to its table. Results are snapshots in key order and are never
/// truncated: more rows than the query's limit stop it with
/// `SQLiteError.Code.rowLimitExceeded`.
@MainActor @Observable
public final class SQLiteLiveQuery<Record: SQLiteRecord> {
    /// The matching records, in key order.
    public private(set) var results: [SQLiteRecordSnapshot<Record>] = []
    /// Whether the first read finished.
    public private(set) var isLoaded = false
    /// The filter.
    public let filter: SQLitePredicate?

    @ObservationIgnored let store: SQLiteModelStore
    @ObservationIgnored let limits: SQLiteQueryLimits?
    /// How many times the results were read, for tests.
    @ObservationIgnored var readCount = 0
    @ObservationIgnored private var progressWaiters: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    /// - Parameters:
    ///   - type: The record type.
    ///   - filter: Which rows to include; `nil` for all.
    ///   - limits: Row and byte limits for each read.
    ///   - store: The store whose committed changes trigger a new read.
    public init(
        _ type: Record.Type, where filter: SQLitePredicate? = nil, limits: SQLiteQueryLimits? = nil,
        store: SQLiteModelStore
    ) {
        self.filter = filter
        self.limits = limits
        self.store = store
    }

    /// Reads the results and keeps them current until the calling task is cancelled.
    public func run(bufferSize: Int = 1024) async throws(SQLiteError) {
        let table = Record.descriptor.table.name
        let filter = self.filter, limits = self.limits
        let read: @Sendable (SQLiteTransaction) throws(SQLiteError) -> [SQLiteRecordSnapshot<Record>] = { (tx) throws(SQLiteError) in
            try tx.fetchAll(Record.self, where: filter, limits: limits)
        }
        while !Task.isCancelled {
            let (rows, changes) = try await store.subscribe(bufferSize: bufferSize, read)
            publish(rows)
            for await event in changes {
                // After resyncRequired the stream ends and the outer loop starts over.
                guard case .committed(let change) = event,
                      change.changes.contains(where: { $0.table == table })
                else { continue }
                publish(try await store.database.read(read))
            }
        }
    }

    private func publish(_ rows: [SQLiteRecordSnapshot<Record>]) {
        if rows != results { results = rows }
        isLoaded = true
        readCount += 1
        var remaining: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in progressWaiters {
            if waiter.condition() { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        progressWaiters = remaining
    }

    /// Suspends until `condition` holds after a read.
    func waitForTesting(_ condition: @escaping () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { progressWaiters.append((condition, $0)) }
    }
}

extension SQLiteModelContext {
    /// A live query over the context's store.
    public func liveQuery<Record: SQLiteRecord>(
        _ type: Record.Type, where filter: SQLitePredicate? = nil, limits: SQLiteQueryLimits? = nil
    ) -> SQLiteLiveQuery<Record> {
        SQLiteLiveQuery(type, where: filter, limits: limits, store: store)
    }
}
