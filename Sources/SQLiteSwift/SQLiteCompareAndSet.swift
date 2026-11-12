// SPDX-License-Identifier: Apache-2.0

/// The result of ``SQLiteTransaction/compareAndSet(table:idColumn:versionColumn:id:expectedVersion:assignments:alsoRequire:)``.
///
/// A conflict is a value, not an error, so callers decide what it means.
///
/// The cases are complete; no case will be added.
public enum SQLiteCompareAndSetResult: Sendable, Hashable {
    /// The row had the expected version and was updated; it now has `newVersion`.
    case updated(newVersion: Int64)
    /// The row exists but has a different version. Reported even if the guard would
    /// also have failed.
    case conflict(currentVersion: Int64)
    /// The row has the expected version, but the `alsoRequire` guard is false for it
    /// (for example the row is already in a terminal state). Nothing was changed.
    case guardFailed(currentVersion: Int64)
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
    /// Runs `UPDATE t SET a = ?, …, version = version + 1 WHERE id = ? AND version = ?
    /// AND (guard)` as one atomic statement. If no row changed, it reads the row once more
    /// to tell a version conflict, a failed guard and a missing row apart. Both
    /// statements run in this transaction.
    ///
    /// - Parameters:
    ///   - table: The table to update.
    ///   - idColumn: The key column. Default `id`.
    ///   - versionColumn: The integer version column. Default `version`.
    ///   - id: The key value.
    ///   - expectedVersion: The version the caller read.
    ///   - assignments: Columns to set. May be empty to only bump the version. Must not
    ///     include the id or version column.
    ///   - alsoRequire: An optional typed guard the row must also meet, for example
    ///     `.notIn("status", ["completed", "failed", "cancelled"])`. Its values are bound
    ///     as parameters. If it fails, the result is ``SQLiteCompareAndSetResult/guardFailed(currentVersion:)``.
    public func compareAndSet(
        table: SQLiteIdentifier,
        idColumn: SQLiteIdentifier = "id",
        versionColumn: SQLiteIdentifier = "version",
        id: SQLiteValue,
        expectedVersion: Int64,
        assignments: [SQLiteAssignment] = [],
        alsoRequire: SQLitePredicate? = nil
    ) throws(SQLiteError) -> SQLiteCompareAndSetResult {
        guard kind == .write else {
            throw .readOnly("compareAndSet needs a write transaction")
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
        var whereClause = "\(idQ) = ? AND \(v) = ?"
        var guardSQL = "1"
        var guardBindings: [SQLiteValue] = []
        if let alsoRequire {
            let rendered = try alsoRequire.render()
            guardSQL = rendered.sql
            guardBindings = rendered.bindings
            whereClause += " AND \(guardSQL)"
            bindings.append(contentsOf: guardBindings)
        }
        let sql = "UPDATE \(t) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClause)"
        let changes = try execute(sql, bindings)
        if changes.changedRows == 1 {
            return .updated(newVersion: expectedVersion + 1)
        }
        guard let row = try queryOne(
            "SELECT \(v), CASE WHEN \(guardSQL) THEN 1 ELSE 0 END FROM \(t) WHERE \(idQ) = ?",
            guardBindings + [id])
        else {
            return .notFound
        }
        let current = try row.integer(0)
        if current != expectedVersion {
            return .conflict(currentVersion: current)
        }
        return .guardFailed(currentVersion: current)
    }
}
