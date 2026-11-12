// SPDX-License-Identifier: Apache-2.0

/// A typed SQL condition with bound values, used by guarded compare-and-set and keyset
/// pagination.
///
/// Column names are quoted (``SQLiteIdentifier``) and values are always bound as
/// parameters, never pasted into SQL. Comparisons follow SQL semantics: a NULL column
/// matches only ``isNull(_:)``. Comparing with a ``SQLiteValue/null`` value is refused;
/// use ``isNull(_:)`` or ``isNotNull(_:)`` instead.
///
/// ```swift
/// let notTerminal: SQLitePredicate = .notIn("status", ["completed", "failed", "cancelled"])
/// let mine: SQLitePredicate = .and([.equals("owner", .text(owner)), notTerminal])
/// ```
///
/// Predicates are built with the static functions below. `SQLitePredicate` is a struct,
/// so new operators can be added in minor releases.
public struct SQLitePredicate: Sendable, Hashable {
    indirect enum Node: Sendable, Hashable {
        case equals(SQLiteIdentifier, SQLiteValue)
        case notEquals(SQLiteIdentifier, SQLiteValue)
        case lessThan(SQLiteIdentifier, SQLiteValue)
        case lessThanOrEqual(SQLiteIdentifier, SQLiteValue)
        case greaterThan(SQLiteIdentifier, SQLiteValue)
        case greaterThanOrEqual(SQLiteIdentifier, SQLiteValue)
        case isIn(SQLiteIdentifier, [SQLiteValue])
        case notIn(SQLiteIdentifier, [SQLiteValue])
        case isNull(SQLiteIdentifier)
        case isNotNull(SQLiteIdentifier)
        case and([SQLitePredicate])
        case or([SQLitePredicate])
        case not(SQLitePredicate)
    }

    let node: Node

    private init(_ node: Node) { self.node = node }

    /// The column equals the value.
    public static func equals(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.equals(column, value))
    }
    /// The column is not NULL and differs from the value.
    public static func notEquals(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.notEquals(column, value))
    }
    public static func lessThan(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.lessThan(column, value))
    }
    public static func lessThanOrEqual(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.lessThanOrEqual(column, value))
    }
    public static func greaterThan(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.greaterThan(column, value))
    }
    public static func greaterThanOrEqual(_ column: SQLiteIdentifier, _ value: SQLiteValue) -> SQLitePredicate {
        SQLitePredicate(.greaterThanOrEqual(column, value))
    }
    /// The column equals one of the values. An empty list matches nothing.
    public static func isIn(_ column: SQLiteIdentifier, _ values: [SQLiteValue]) -> SQLitePredicate {
        SQLitePredicate(.isIn(column, values))
    }
    /// The column is not NULL and equals none of the values. An empty list matches every
    /// non-NULL value.
    public static func notIn(_ column: SQLiteIdentifier, _ values: [SQLiteValue]) -> SQLitePredicate {
        SQLitePredicate(.notIn(column, values))
    }
    public static func isNull(_ column: SQLiteIdentifier) -> SQLitePredicate {
        SQLitePredicate(.isNull(column))
    }
    public static func isNotNull(_ column: SQLiteIdentifier) -> SQLitePredicate {
        SQLitePredicate(.isNotNull(column))
    }
    /// All conditions hold. An empty list is true.
    public static func and(_ parts: [SQLitePredicate]) -> SQLitePredicate {
        SQLitePredicate(.and(parts))
    }
    /// At least one condition holds. An empty list is false.
    public static func or(_ parts: [SQLitePredicate]) -> SQLitePredicate {
        SQLitePredicate(.or(parts))
    }
    /// The condition does not hold.
    public static func not(_ inner: SQLitePredicate) -> SQLitePredicate {
        SQLitePredicate(.not(inner))
    }

    /// The most values one ``isIn(_:_:)`` or ``notIn(_:_:)`` may list.
    public static let maxListCount = 1000
    /// The deepest nesting of ``and(_:)``, ``or(_:)`` and ``not(_:)``.
    public static let maxDepth = 32

    /// Renders the predicate as a parenthesized SQL condition and its bindings, in
    /// placeholder order.
    public func render() throws(SQLiteError) -> (sql: String, bindings: [SQLiteValue]) {
        var bindings: [SQLiteValue] = []
        let sql = try render(into: &bindings, depth: 0)
        return (sql, bindings)
    }

    private func render(into bindings: inout [SQLiteValue], depth: Int) throws(SQLiteError) -> String {
        guard depth <= Self.maxDepth else {
            throw .invalidArgument("predicate nesting is deeper than \(Self.maxDepth)")
        }
        func comparison(_ column: SQLiteIdentifier, _ op: String, _ value: SQLiteValue) throws(SQLiteError) -> String {
            guard value != .null else {
                throw .invalidArgument("comparing \(column) with NULL; use .isNull or .isNotNull")
            }
            bindings.append(value)
            return "(\(try column.quoted()) \(op) ?)"
        }
        func list(_ column: SQLiteIdentifier, _ values: [SQLiteValue], negated: Bool) throws(SQLiteError) -> String {
            guard values.count <= Self.maxListCount else {
                throw .invalidArgument("a predicate list has more than \(Self.maxListCount) values")
            }
            guard !values.contains(.null) else {
                throw .invalidArgument("a predicate list for \(column) contains NULL")
            }
            let quoted = try column.quoted()
            if values.isEmpty { return negated ? "(\(quoted) IS NOT NULL)" : "(0)" }
            bindings.append(contentsOf: values)
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            return "(\(quoted) \(negated ? "NOT IN" : "IN") (\(placeholders)))"
        }
        switch node {
        case .equals(let c, let v): return try comparison(c, "=", v)
        case .notEquals(let c, let v): return try comparison(c, "<>", v)
        case .lessThan(let c, let v): return try comparison(c, "<", v)
        case .lessThanOrEqual(let c, let v): return try comparison(c, "<=", v)
        case .greaterThan(let c, let v): return try comparison(c, ">", v)
        case .greaterThanOrEqual(let c, let v): return try comparison(c, ">=", v)
        case .isIn(let c, let values): return try list(c, values, negated: false)
        case .notIn(let c, let values): return try list(c, values, negated: true)
        case .isNull(let c): return "(\(try c.quoted()) IS NULL)"
        case .isNotNull(let c): return "(\(try c.quoted()) IS NOT NULL)"
        case .and(let parts):
            if parts.isEmpty { return "(1)" }
            var rendered: [String] = []
            for part in parts { rendered.append(try part.render(into: &bindings, depth: depth + 1)) }
            return "(\(rendered.joined(separator: " AND ")))"
        case .or(let parts):
            if parts.isEmpty { return "(0)" }
            var rendered: [String] = []
            for part in parts { rendered.append(try part.render(into: &bindings, depth: depth + 1)) }
            return "(\(rendered.joined(separator: " OR ")))"
        case .not(let inner):
            return "(NOT \(try inner.render(into: &bindings, depth: depth + 1)))"
        }
    }
}

// MARK: - Keyset pagination

/// The position after the last row of a page: the values of its key columns.
public struct SQLiteKeysetCursor: Sendable, Hashable {
    public var values: [SQLiteValue]

    public init(values: [SQLiteValue]) {
        self.values = values
    }
}

/// One page of a keyset-paginated query.
public struct SQLiteKeysetPage: Sendable, Hashable {
    /// The rows, in key order. Each row contains the requested columns followed by any
    /// key columns that weren't requested.
    public var rows: [SQLiteRow]
    /// The cursor for the next page, or `nil` if this page had fewer rows than the limit
    /// (there are no more rows).
    public var nextCursor: SQLiteKeysetCursor?
}

extension SQLiteTransaction {
    /// Reads one page of rows in key order, starting after `cursor`.
    ///
    /// Runs `SELECT … FROM table WHERE (filter) AND (k1, k2, …) > (?, ?, …)
    /// ORDER BY k1, k2, … LIMIT ?`. Keyset pagination stays fast and stable while rows
    /// are inserted or deleted between pages, unlike `OFFSET`.
    ///
    /// The key columns must be `NOT NULL` and identify a row uniquely together (for
    /// example `(created_at, id)`); an index on them keeps every page cheap.
    ///
    /// - Parameters:
    ///   - table: The table to read.
    ///   - columns: The columns to return. Key columns not listed are appended.
    ///   - keyColumns: The ordering key, most significant first.
    ///   - descending: Read in descending key order.
    ///   - cursor: The previous page's ``SQLiteKeysetPage/nextCursor``, or `nil` for the
    ///     first page.
    ///   - filter: An optional condition every row must meet.
    ///   - limit: Rows per page, at most ``SQLiteLimits/defaultMaxRows``.
    ///   - maxBytes: The page's byte budget (default ``SQLiteLimits/defaultMaxResultBytes``).
    public func queryPage(
        table: SQLiteIdentifier,
        columns: [SQLiteIdentifier],
        keyColumns: [SQLiteIdentifier],
        descending: Bool = false,
        after cursor: SQLiteKeysetCursor? = nil,
        filter: SQLitePredicate? = nil,
        limit: Int,
        maxBytes: Int? = nil
    ) throws(SQLiteError) -> SQLiteKeysetPage {
        guard !keyColumns.isEmpty else { throw .invalidArgument("keyColumns must not be empty") }
        guard limit > 0, limit <= limits.defaultMaxRows else {
            throw .invalidArgument("limit must be in 1...\(limits.defaultMaxRows)")
        }
        var selected = columns
        for key in keyColumns where !selected.contains(key) {
            selected.append(key)
        }
        let keyPositions = keyColumns.map { key in selected.firstIndex(of: key)! }
        let t = try table.quoted()
        var selectList: [String] = []
        for column in selected { selectList.append(try column.quoted()) }
        var keyList: [String] = []
        for key in keyColumns { keyList.append(try key.quoted()) }

        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let filter {
            let rendered = try filter.render()
            conditions.append(rendered.sql)
            bindings.append(contentsOf: rendered.bindings)
        }
        if let cursor {
            guard cursor.values.count == keyColumns.count else {
                throw .invalidArgument("the cursor has \(cursor.values.count) values for \(keyColumns.count) key columns")
            }
            guard !cursor.values.contains(.null) else {
                throw .invalidArgument("cursor values must not be NULL")
            }
            let placeholders = Array(repeating: "?", count: keyColumns.count).joined(separator: ", ")
            conditions.append("((\(keyList.joined(separator: ", "))) \(descending ? "<" : ">") (\(placeholders)))")
            bindings.append(contentsOf: cursor.values)
        }
        let direction = descending ? "DESC" : "ASC"
        var sql = "SELECT \(selectList.joined(separator: ", ")) FROM \(t)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY " + keyList.map { "\($0) \(direction)" }.joined(separator: ", ")
        sql += " LIMIT ?"
        bindings.append(.integer(Int64(limit)))

        let rows = try query(sql, bindings, limits: SQLiteQueryLimits(maxRows: limit, maxBytes: maxBytes))
        var next: SQLiteKeysetCursor?
        if rows.count == limit, let last = rows.last {
            next = SQLiteKeysetCursor(values: keyPositions.map { last[$0] })
        }
        return SQLiteKeysetPage(rows: rows, nextCursor: next)
    }
}
