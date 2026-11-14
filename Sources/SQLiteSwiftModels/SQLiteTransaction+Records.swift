// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

extension SQLiteTransaction {
    /// Reads one record and its version, or `nil` if no row has this key.
    ///
    /// A stored value that doesn't decode throws ``SQLiteError/Code/invalidStoredValue``
    /// naming the column; nothing is repaired or skipped.
    public func fetch<Record: SQLiteRecord>(
        _ type: Record.Type, id: Record.ID
    ) throws(SQLiteError) -> SQLiteRecordSnapshot<Record>? {
        let descriptor = Record.descriptor
        try descriptor.validate()
        let sql = try selectSQL(descriptor) + " WHERE \(try SQLiteIdentifier(descriptor.keyColumn).quoted()) = ?"
        let rows = try queryRaw(sql, [try descriptor.encodeKey(id)], limits: SQLiteQueryLimits(maxRows: 1))
        guard let row = rows.first else { return nil }
        return try descriptor.decode(row.values)
    }

    /// Reads the records matching `filter`, in key order, within row and byte limits.
    ///
    /// More rows than the limit throw ``SQLiteError/Code/rowLimitExceeded`` (results
    /// are never truncated). Use `limits` to raise or lower the bound.
    public func fetchAll<Record: SQLiteRecord>(
        _ type: Record.Type,
        where filter: SQLitePredicate? = nil,
        limits: SQLiteQueryLimits? = nil
    ) throws(SQLiteError) -> [SQLiteRecordSnapshot<Record>] {
        let descriptor = Record.descriptor
        try descriptor.validate()
        var sql = try selectSQL(descriptor)
        var bindings: [SQLiteRawValue] = []
        if let filter {
            let rendered = try filter.render()
            sql += " WHERE " + rendered.sql
            bindings = rendered.bindings.map(SQLiteRawValue.init)
        }
        sql += " ORDER BY \(try SQLiteIdentifier(descriptor.keyColumn).quoted())"
        var snapshots: [SQLiteRecordSnapshot<Record>] = []
        for row in try queryRaw(sql, bindings, limits: limits) {
            snapshots.append(try descriptor.decode(row.values))
        }
        return snapshots
    }

    /// Checks that the record's table exists and has every mapped column plus the
    /// revision and incarnation columns. Throws ``SQLiteError/Code/schemaMismatch``
    /// otherwise. Extra columns are allowed.
    public func verifySchema<Record: SQLiteRecord>(for type: Record.Type) throws(SQLiteError) {
        let descriptor = Record.descriptor
        try descriptor.validate()
        let rows = try query("SELECT name FROM pragma_table_info(?)", [.text(descriptor.table.name)])
        guard !rows.isEmpty else {
            throw .schemaMismatch(setting: descriptor.table.name, expected: "table present", actual: "missing")
        }
        var present = Set<String>()
        for row in rows { present.insert(try row.text(0)) }
        for column in descriptor.columnNames + [descriptor.revisionColumn, descriptor.incarnationColumn]
        where !present.contains(column) {
            throw .schemaMismatch(setting: "\(descriptor.table.name).\(column)", expected: "column present", actual: "missing")
        }
    }

    private func selectSQL<Record>(_ descriptor: SQLiteRecordDescriptor<Record>) throws(SQLiteError) -> String {
        var names: [String] = []
        for name in descriptor.columnNames + [descriptor.revisionColumn, descriptor.incarnationColumn] {
            names.append(try SQLiteIdentifier(name).quoted())
        }
        return "SELECT \(names.joined(separator: ", ")) FROM \(try descriptor.table.quoted())"
    }
}
