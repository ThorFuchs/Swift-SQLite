// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

extension SQLiteTransaction {
    /// Inserts `record` only if no row has its key.
    ///
    /// The row gets revision 1 and a new random incarnation. If a row with the key
    /// exists, nothing changes and the outcome is
    /// ``SQLiteRecordWriteOutcome/conflict(current:)``.
    public func insert<Record: SQLiteRecord>(
        _ record: Record
    ) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record> {
        try save(record, expecting: .absent)
    }

    /// Updates `record` only if its row still has `expected` (revision and
    /// incarnation). The revision grows by one.
    ///
    /// - Returns: ``SQLiteRecordWriteOutcome/updated(_:)``, or
    ///   ``SQLiteRecordWriteOutcome/conflict(current:)`` if the row has another version
    ///   (also when it was deleted and inserted again under the same key), or
    ///   ``SQLiteRecordWriteOutcome/missing`` if no row has the key.
    /// - Throws: `SQLiteError.Code.invalidArgument` if the revision is already
    ///   `Int64.max`; it is never wrapped.
    public func update<Record: SQLiteRecord>(
        _ record: Record, expecting expected: SQLiteRecordVersion
    ) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record> {
        try save(record, expecting: .version(expected))
    }

    /// Inserts or updates `record`, depending on what the caller expects to find.
    ///
    /// There is no write without an expectation: `.absent` inserts and `.version`
    /// updates, and neither overwrites a row it didn't expect.
    public func save<Record: SQLiteRecord>(
        _ record: Record, expecting expectation: SQLiteWriteExpectation
    ) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record> {
        try save(record, expecting: expectation, incarnation: SQLiteRecordVersion.newIncarnation())
    }

    /// `save` with the incarnation an insert gets. The context chooses it before the
    /// write, so it knows the exact version even when the commit outcome is unknown.
    package func save<Record: SQLiteRecord>(
        _ record: Record, expecting expectation: SQLiteWriteExpectation, incarnation: [UInt8]
    ) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record> {
        let d = Record.descriptor
        try d.validate()
        let values = try d.encode(record)
        let key = values[0]
        let table = try d.table.quoted()
        let keyQ = try SQLiteIdentifier(d.keyColumn).quoted()
        switch expectation {
        case .absent:
            var names: [String] = []
            for name in d.columnNames + [d.revisionColumn, d.incarnationColumn] {
                names.append(try SQLiteIdentifier(name).quoted())
            }
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            // The existence check and the insert are one statement, so the key is
            // checked even when the table has no unique constraint on it.
            let sql = """
                INSERT INTO \(table) (\(names.joined(separator: ", "))) \
                SELECT \(placeholders), 1, ? \
                WHERE NOT EXISTS (SELECT 1 FROM \(table) WHERE \(keyQ) = ?)
                """
            guard incarnation.count == SQLiteRecordVersion.incarnationByteCount else {
                throw .invalidArgument("an incarnation has 16 bytes, got \(incarnation.count)")
            }
            let changes = try executeRaw(sql, values + [.blob(incarnation), key])
            let stored = try storedSnapshot(Record.self, id: record.id)
            if changes.changedRows == 1 {
                return .inserted(stored)
            }
            return .conflict(current: stored)

        case .version(let expected):
            var assignments: [SQLiteAssignment] = []
            for (name, value) in zip(d.columnNames, values).dropFirst() {
                assignments.append(SQLiteAssignment(SQLiteIdentifier(name), try bindable(value, column: name)))
            }
            let result = try compareAndSet(
                table: d.table,
                idColumn: SQLiteIdentifier(d.keyColumn),
                versionColumn: SQLiteIdentifier(d.revisionColumn),
                id: try bindable(key, column: d.keyColumn),
                expectedVersion: expected.revision,
                assignments: assignments,
                alsoRequire: .equals(SQLiteIdentifier(d.incarnationColumn), .blob(expected.incarnation)))
            switch result {
            case .updated:
                return .updated(try storedSnapshot(Record.self, id: record.id))
            case .conflict, .guardFailed:
                return .conflict(current: try storedSnapshot(Record.self, id: record.id))
            case .notFound:
                return .missing
            }
        }
    }

    /// Deletes the row with key `id` only if it still has `expected` (revision and
    /// incarnation).
    ///
    /// - Returns: ``SQLiteRecordWriteOutcome/deleted``,
    ///   ``SQLiteRecordWriteOutcome/conflict(current:)`` if the row has another
    ///   version, or ``SQLiteRecordWriteOutcome/missing`` if no row has the key.
    public func delete<Record: SQLiteRecord>(
        _ type: Record.Type, id: Record.ID, expecting expected: SQLiteRecordVersion
    ) throws(SQLiteError) -> SQLiteRecordWriteOutcome<Record> {
        let d = Record.descriptor
        try d.validate()
        let sql = """
            DELETE FROM \(try d.table.quoted()) \
            WHERE \(try SQLiteIdentifier(d.keyColumn).quoted()) = ? \
            AND \(try SQLiteIdentifier(d.revisionColumn).quoted()) = ? \
            AND \(try SQLiteIdentifier(d.incarnationColumn).quoted()) = ?
            """
        let changes = try executeRaw(sql, [try d.encodeKey(id), .integer(expected.revision), .blob(expected.incarnation)])
        if changes.changedRows == 1 {
            return .deleted
        }
        if changes.changedRows > 1 {
            throw .misuse("\(changes.changedRows) rows of \(d.table.name) have the same key; the key column must be unique")
        }
        guard let current = try fetch(Record.self, id: id) else { return .missing }
        return .conflict(current: current)
    }

    /// The row just written or found; it exists because this transaction saw it.
    private func storedSnapshot<Record: SQLiteRecord>(
        _ type: Record.Type, id: Record.ID
    ) throws(SQLiteError) -> SQLiteRecordSnapshot<Record> {
        guard let snapshot = try fetch(Record.self, id: id) else {
            throw .misuse("the row of \(Record.descriptor.table.name) disappeared inside its write transaction")
        }
        return snapshot
    }

    /// Converts an encoded value for the core's compare-and-set, which binds
    /// ``SQLiteValue``s. TEXT from a codec is valid UTF-8; anything else is a codec bug.
    private func bindable(_ raw: SQLiteRawValue, column: String) throws(SQLiteError) -> SQLiteValue {
        switch raw {
        case .null: return .null
        case .integer(let v): return .integer(v)
        case .real(let v): return .real(v)
        case .blob(let b): return .blob(b)
        case .text(let bytes):
            guard let string = String(validating: bytes, as: UTF8.self) else {
                throw .invalidArgument("the codec of column \(column) produced TEXT that isn't valid UTF-8")
            }
            return .text(string)
        }
    }
}
