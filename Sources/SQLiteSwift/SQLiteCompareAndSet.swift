// SPDX-License-Identifier: Apache-2.0

/// The result of ``SQLiteTransaction/compareAndSet(table:idColumn:versionColumn:id:expectedVersion:assignments:)``.
///
/// A conflict is a value, not an error, so callers decide what it means.
public enum SQLiteCompareAndSetResult: Sendable, Hashable {
    /// The row had the expected version and was updated; it now has `newVersion`.
    case updated(newVersion: Int64)
    /// The row exists but has a different version.
    case conflict(currentVersion: Int64)
    /// No row has this id.
    case notFound
}

/// One `column = value` assignment for a compare-and-set update.
public struct SQLiteAssignment: Sendable, Hashable {
    public var column: SQLiteIdentifier
    public var value: SQLiteValue

    public init(_ column: SQLiteIdentifier, _ value: SQLiteValue) {
        self.column = column
        self.value = value
    }
}

extension SQLiteTransaction {
    /// Updates a row only if its version column still has the expected value.
    ///
    /// Runs `UPDATE t SET a = ?, …, version = version + 1 WHERE id = ? AND version = ?`.
    /// If no row changed, it reads the current version to tell a conflict from a
    /// missing row. Both statements run in this transaction.
    ///
    /// - Parameters:
    ///   - table: The table to update.
    ///   - idColumn: The key column. Default `id`.
    ///   - versionColumn: The integer version column. Default `version`.
    ///   - id: The key value.
    ///   - expectedVersion: The version the caller read.
    ///   - assignments: Columns to set. May be empty to only bump the version. Must not
    ///     include the id or version column.
    public func compareAndSet(
        table: SQLiteIdentifier,
        idColumn: SQLiteIdentifier = "id",
        versionColumn: SQLiteIdentifier = "version",
        id: SQLiteValue,
        expectedVersion: Int64,
        assignments: [SQLiteAssignment] = []
    ) throws(SQLiteError) -> SQLiteCompareAndSetResult {
        guard kind == .write else {
            throw .readOnly(SQLiteErrorDetails(code: .readOnly, message: "compareAndSet needs a write transaction"))
        }
        guard expectedVersion < Int64.max else {
            throw .invalidArgument("expectedVersion is at Int64.max and cannot be incremented")
        }
        let t = try table.quoted(), idQ = try idColumn.quoted(), v = try versionColumn.quoted()
        var setClauses: [String] = []
        var bindings: [SQLiteValue] = []
        var seen: Set<String> = [idColumn.name, versionColumn.name]
        for assignment in assignments {
            guard seen.insert(assignment.column.name).inserted else {
                throw .invalidArgument("column \(assignment.column) is assigned twice or is the id/version column")
            }
            setClauses.append("\(try assignment.column.quoted()) = ?")
            bindings.append(assignment.value)
        }
        setClauses.append("\(v) = \(v) + 1")
        bindings.append(id)
        bindings.append(.integer(expectedVersion))
        let sql = "UPDATE \(t) SET \(setClauses.joined(separator: ", ")) WHERE \(idQ) = ? AND \(v) = ?"
        let changes = try execute(sql, bindings)
        if changes.changedRows == 1 {
            return .updated(newVersion: expectedVersion + 1)
        }
        guard let row = try queryOne("SELECT \(v) FROM \(t) WHERE \(idQ) = ?", [id]) else {
            return .notFound
        }
        return .conflict(currentVersion: try row.integer(0))
    }
}
