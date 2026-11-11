// SPDX-License-Identifier: Apache-2.0

extension SQLiteTransaction {
    /// The current time from the configured clock (``SQLiteConfiguration/clock``).
    ///
    /// Expiry helpers use this; they never read the wall clock directly.
    public func now() -> SQLiteTimestamp {
        clock.now()
    }

    /// The timestamp `duration` from now, by the configured clock.
    public func deadline(after duration: Duration) -> SQLiteTimestamp {
        clock.now().advanced(by: duration)
    }

    /// Deletes up to `limit` rows whose expiry column is at or before now.
    ///
    /// The expiry column holds ``SQLiteTimestamp`` milliseconds. Rows with a NULL
    /// expiry never expire. The batch is bounded by `limit`; call again to delete more.
    ///
    /// - Returns: The number of rows deleted.
    @discardableResult
    public func deleteExpired(
        from table: SQLiteIdentifier, expiresAtColumn: SQLiteIdentifier, limit: Int
    ) throws(SQLiteError) -> Int {
        guard limit > 0 else { throw .invalidArgument("limit must be positive") }
        let t = try table.quoted(), e = try expiresAtColumn.quoted()
        let cutoff = now()
        let sql = "DELETE FROM \(t) WHERE rowid IN (SELECT rowid FROM \(t) WHERE \(e) IS NOT NULL AND \(e) <= ? LIMIT ?)"
        return try execute(sql, [cutoff.sqliteValue, .integer(Int64(limit))]).changedRows
    }

    /// Counts rows whose expiry column is at or before now.
    public func countExpired(
        in table: SQLiteIdentifier, expiresAtColumn: SQLiteIdentifier
    ) throws(SQLiteError) -> Int {
        let t = try table.quoted(), e = try expiresAtColumn.quoted()
        let value = try scalar("SELECT count(*) FROM \(t) WHERE \(e) IS NOT NULL AND \(e) <= ?", [now().sqliteValue])
        guard case .integer(let count) = value else { return 0 }
        return Int(count)
    }
}
