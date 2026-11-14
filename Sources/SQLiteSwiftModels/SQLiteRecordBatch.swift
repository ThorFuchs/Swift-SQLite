// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// One managed write in a batch, for any record type.
///
/// Build it with ``insert(_:)``, ``update(_:expecting:)``, ``save(_:expecting:)`` or
/// ``delete(_:id:expecting:)`` and pass a list of them to
/// ``SQLiteSwift/SQLiteDatabase/writeRecords(_:limits:)``.
public struct SQLiteRecordWrite: Sendable {
    /// The table the write goes to.
    public let table: String
    let apply: @Sendable (SQLiteTransaction) throws(SQLiteError) -> SQLiteRecordWriteReport.Body

    init<Record: SQLiteRecord>(
        _ type: Record.Type,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record>
    ) {
        table = Record.descriptor.table.name
        apply = { (transaction) throws(SQLiteError) in
            SQLiteRecordWriteReport.Body(try body(transaction))
        }
    }

    /// Inserts `record` if no row has its key.
    public static func insert<Record: SQLiteRecord>(_ record: Record) -> SQLiteRecordWrite {
        save(record, expecting: .absent)
    }

    /// Updates `record` if its row still has `expected`.
    public static func update<Record: SQLiteRecord>(
        _ record: Record, expecting expected: SQLiteRecordVersion
    ) -> SQLiteRecordWrite {
        save(record, expecting: .version(expected))
    }

    /// Inserts or updates `record`, depending on `expectation`.
    public static func save<Record: SQLiteRecord>(
        _ record: Record, expecting expectation: SQLiteWriteExpectation
    ) -> SQLiteRecordWrite {
        SQLiteRecordWrite(Record.self) { (transaction) throws(SQLiteError) in
            try transaction.save(record, expecting: expectation)
        }
    }

    /// Deletes the row with key `id` if it still has `expected`.
    public static func delete<Record: SQLiteRecord>(
        _ type: Record.Type, id: Record.ID, expecting expected: SQLiteRecordVersion
    ) -> SQLiteRecordWrite {
        SQLiteRecordWrite(Record.self) { (transaction) throws(SQLiteError) in
            try transaction.delete(Record.self, id: id, expecting: expected)
        }
    }
}

/// The outcome of one write in a batch.
public struct SQLiteRecordWriteReport: Sendable {
    /// The write's position in the batch.
    public let index: Int
    /// The table it went to.
    public let table: String
    let body: Body

    /// The outcome without its record type.
    ///
    /// The cases are complete; no case will be added.
    public enum Summary: Sendable, Hashable {
        case inserted(SQLiteRecordVersion)
        case updated(SQLiteRecordVersion)
        case deleted
        case conflict(current: SQLiteRecordVersion)
        case missing
    }

    /// The outcome without its record type, for code that handles any record.
    public var summary: Summary { body.summary }

    /// Whether the write changed its row.
    public var isApplied: Bool {
        switch body.summary {
        case .inserted, .updated, .deleted: true
        case .conflict, .missing: false
        }
    }

    /// The typed outcome, or `nil` if the write was for another record type.
    public func outcome<Record: SQLiteRecord>(as type: Record.Type) -> SQLiteRecordWriteOutcome<Record>? {
        body.outcome as? SQLiteRecordWriteOutcome<Record>
    }

    struct Body: Sendable {
        let summary: Summary
        let outcome: any Sendable

        init<Record: SQLiteRecord>(_ outcome: SQLiteRecordWriteOutcome<Record>) {
            self.outcome = outcome
            summary = switch outcome {
            case .inserted(let s): .inserted(s.version)
            case .updated(let s): .updated(s.version)
            case .deleted: .deleted
            case .conflict(let s): .conflict(current: s.version)
            case .missing: .missing
            }
        }
    }
}

/// The result of a batch of managed writes.
///
/// The cases are complete; no case will be added.
public enum SQLiteRecordBatchOutcome: Sendable {
    /// Every write applied and the transaction committed. One report per write, in
    /// order.
    case committed([SQLiteRecordWriteReport])
    /// A write found a conflict or a missing row. The whole batch was rolled back, so
    /// no write of it is stored; `failure` names the write that stopped it. Later
    /// writes didn't run.
    case rolledBack(failure: SQLiteRecordWriteReport)
}

extension SQLiteDatabase {
    /// Runs `writes` in order in one write transaction, all or nothing.
    ///
    /// The first write that doesn't apply (a conflict or a missing row) rolls back
    /// the whole batch and is reported in ``SQLiteRecordBatchOutcome/rolledBack(failure:)``.
    /// Errors (busy, deadline, cancellation, constraint violations) throw and also
    /// roll back. An empty batch commits without opening a transaction.
    ///
    /// - Parameters:
    ///   - writes: The writes, in the order they run.
    ///   - limits: Time and instruction bounds for the transaction. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    @discardableResult
    public func writeRecords(
        _ writes: [SQLiteRecordWrite], limits: SQLiteOperationLimits? = nil
    ) async throws(SQLiteError) -> SQLiteRecordBatchOutcome {
        guard !writes.isEmpty else { return .committed([]) }
        return try await writeOrRollback(limits: limits) { (transaction) throws(SQLiteError) in
            var reports: [SQLiteRecordWriteReport] = []
            reports.reserveCapacity(writes.count)
            for (index, write) in writes.enumerated() {
                let report = SQLiteRecordWriteReport(index: index, table: write.table, body: try write.apply(transaction))
                guard report.isApplied else {
                    return .rollback(.rolledBack(failure: report))
                }
                reports.append(report)
            }
            return .commit(.committed(reports))
        }
    }
}
