// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif

/// An open transaction, passed to the closures of ``SQLiteDatabase/read(_:)`` and
/// ``SQLiteDatabase/write(_:)``.
///
/// A transaction is valid only inside its closure and only on the thread that calls
/// the closure; it isn't `Sendable`. Using it afterwards throws
/// ``SQLiteError/misuse(_:)``. Transaction control statements (`BEGIN`, `COMMIT`,
/// `ROLLBACK`) are refused; SQLiteSwift owns the transaction. `SAVEPOINT` is allowed.
public final class SQLiteTransaction {
    /// Whether a transaction may write.
    public enum Kind: Sendable, Hashable {
        /// A deferred read transaction: one WAL snapshot for the whole closure.
        case read
        /// A `BEGIN IMMEDIATE` write transaction on the single writer connection.
        case write
    }

    public let kind: Kind
    let core: SQLiteConnectionCore
    private var isValid = true

    init(core: SQLiteConnectionCore, kind: Kind) {
        self.core = core
        self.kind = kind
    }

    func invalidate() { isValid = false }

    /// The clock from ``SQLiteConfiguration/clock``.
    public var clock: any SQLiteClock { core.configuration.clock }

    /// The configured limits.
    public var limits: SQLiteLimits { core.configuration.limits }

    private func ensureUsable() throws(SQLiteError) {
        guard isValid else {
            throw .misuse("a transaction was used after its closure returned")
        }
        try core.checkCancelled()
    }

    private func checkWritable(_ statement: OpaquePointer) throws(SQLiteError) {
        if kind == .read, sqlite3_stmt_readonly(statement) == 0 {
            throw .readOnly("a read transaction cannot run statements that write")
        }
    }

    private func resolve(_ limits: SQLiteQueryLimits?) throws(SQLiteError) -> (rows: Int, bytes: Int) {
        let configured = core.configuration.limits
        let rows = limits?.maxRows ?? configured.defaultMaxRows
        let bytes = limits?.maxBytes ?? configured.defaultMaxResultBytes
        guard rows > 0 else { throw .invalidArgument("maxRows must be positive") }
        guard bytes > 0, bytes <= configured.hardMaxResultBytes else {
            throw .invalidArgument("maxBytes must be in 1...\(configured.hardMaxResultBytes) (the hard cap)")
        }
        return (rows, bytes)
    }

    // MARK: Statements

    /// Runs one statement that returns no rows of interest.
    ///
    /// - Parameters:
    ///   - sql: Exactly one SQL statement. Use `?` placeholders for values.
    ///   - bindings: One value per placeholder, in order.
    /// - Returns: The rows changed and the last inserted rowid.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws(SQLiteError) -> SQLiteChanges {
        try ensureUsable()
        let (statement, isCached) = try core.prepare(sql, cached: true)
        defer { core.release(statement, isCached: isCached) }
        try checkWritable(statement)
        try core.bind(bindings, to: statement)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw core.error(rc) }
            try core.checkCancelled()
        }
        let db = try core.handle()
        return SQLiteChanges(
            changedRows: Int(sqlite3_changes64(db)),
            lastInsertRowID: sqlite3_last_insert_rowid(db))
    }

    /// Runs several `;`-separated statements without bindings (for example a
    /// migration script). Statements aren't cached.
    public func executeScript(_ sql: String) throws(SQLiteError) {
        try ensureUsable()
        let db = try core.handle()
        var failure: SQLiteError?
        sql.withCString { start in
            var cursor: UnsafePointer<CChar>? = start
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, current, -1, &statement, &tail)
                guard rc == SQLITE_OK else { failure = core.error(rc); return }
                cursor = tail
                guard let statement else { continue }  // whitespace or comment
                defer { sqlite3_finalize(statement) }
                if kind == .read, sqlite3_stmt_readonly(statement) == 0 {
                    failure = .readOnly("a read transaction cannot run statements that write")
                    return
                }
                while true {
                    if core.activeToken?.isCancelled == true { failure = .interrupted; return }
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { failure = core.error(step); return }
                }
            }
        }
        if let failure { throw failure }
    }

    /// Runs a query and returns all rows, within row and byte limits.
    ///
    /// More rows than the row limit throw ``SQLiteError/rowLimitExceeded(limit:)``;
    /// more bytes than the byte budget throw ``SQLiteError/resultTooLarge(limit:)``.
    /// Results are never silently truncated.
    public func query(
        _ sql: String, _ bindings: [SQLiteValue] = [], limits: SQLiteQueryLimits? = nil
    ) throws(SQLiteError) -> [SQLiteRow] {
        try ensureUsable()
        let (maxRows, maxBytes) = try resolve(limits)
        let (statement, isCached) = try core.prepare(sql, cached: true)
        defer { core.release(statement, isCached: isCached) }
        try checkWritable(statement)
        try core.bind(bindings, to: statement)
        return try core.collectRows(statement, maxRows: maxRows, maxBytes: maxBytes)
    }

    /// Runs a query expected to return at most one row.
    public func queryOne(
        _ sql: String, _ bindings: [SQLiteValue] = [], maxBytes: Int? = nil
    ) throws(SQLiteError) -> SQLiteRow? {
        try query(sql, bindings, limits: SQLiteQueryLimits(maxRows: 1, maxBytes: maxBytes)).first
    }

    /// Runs a query and returns the first column of the first row, or `nil` if there
    /// is no row.
    public func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws(SQLiteError) -> SQLiteValue? {
        try queryOne(sql, bindings)?.values.first
    }

    // MARK: Bounded BLOB reads

    /// Reads one BLOB (or text) column, checking its size with `length(column)` before
    /// loading it.
    ///
    /// The size check runs as its own query, so SQLite never loads an oversized value
    /// into memory. Both queries run in this transaction's snapshot.
    ///
    /// - Returns: The bytes, or `nil` if no row matches or the column is NULL.
    /// - Throws: ``SQLiteError/resultTooLarge(limit:)`` if the value is larger than
    ///   `maxBytes` (default: ``SQLiteLimits/defaultMaxResultBytes``).
    public func readBlob(
        table: SQLiteIdentifier,
        column: SQLiteIdentifier,
        keyColumn: SQLiteIdentifier,
        key: SQLiteValue,
        maxBytes: Int? = nil
    ) throws(SQLiteError) -> [UInt8]? {
        let (_, limit) = try resolve(SQLiteQueryLimits(maxRows: 1, maxBytes: maxBytes))
        let t = try table.quoted(), c = try column.quoted(), k = try keyColumn.quoted()
        guard let lengthRow = try queryOne("SELECT length(\(c)) FROM \(t) WHERE \(k) = ?", [key]) else {
            return nil
        }
        guard let length = try lengthRow.optionalInteger(0) else { return nil }
        guard length <= Int64(limit) else { throw .resultTooLarge(limit: limit) }
        guard let row = try queryOne("SELECT \(c) FROM \(t) WHERE \(k) = ?", [key], maxBytes: limit) else {
            return nil
        }
        switch row[0] {
        case .null: return nil
        case .blob(let bytes): return bytes
        case .text(let text): return Array(text.utf8)
        case let other: throw .typeMismatch(column: 0, expected: .blob, actual: other.kind)
        }
    }

    // MARK: Schema

    /// The database's `PRAGMA user_version`.
    public func userVersion() throws(SQLiteError) -> Int {
        try ensureUsable()
        guard case .integer(let version) = try core.scalarInternal("PRAGMA user_version") else { return 0 }
        return Int(version)
    }

    /// The number of statements currently in this connection's statement cache.
    public var cachedStatementCount: Int { core.cache.count }
}
