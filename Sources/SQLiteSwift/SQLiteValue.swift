// SPDX-License-Identifier: Apache-2.0

/// A SQLite storage-class value, used for bindings and results.
///
/// Consumers that store JSON pass canonical bytes as ``blob(_:)``; SQLiteSwift does
/// not interpret them.
public enum SQLiteValue: Sendable, Hashable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])

    /// The storage class of this value.
    public var kind: SQLiteValueKind {
        switch self {
        case .null: .null
        case .integer: .integer
        case .real: .real
        case .text: .text
        case .blob: .blob
        }
    }

    /// The number of bytes this value counts against a result budget.
    ///
    /// Integers and reals count as 8 bytes, text as its UTF-8 length and BLOBs as
    /// their length.
    public var byteCount: Int {
        switch self {
        case .null: 0
        case .integer, .real: 8
        case .text(let s): s.utf8.count
        case .blob(let b): b.count
        }
    }

    public var description: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .text(let s): "'\(s)'"
        case .blob(let b): "BLOB(\(b.count) bytes)"
        }
    }
}

extension SQLiteValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension SQLiteValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension SQLiteValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .real(value) }
}

extension SQLiteValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

extension SQLiteValue {
    /// Wraps an `Int` as ``integer(_:)``.
    public init(_ value: Int) { self = .integer(Int64(value)) }
    /// Wraps an `Int64` as ``integer(_:)``.
    public init(_ value: Int64) { self = .integer(value) }
    /// Wraps a `Bool` as ``integer(_:)`` 0 or 1.
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    /// Wraps a `Double` as ``real(_:)``.
    public init(_ value: Double) { self = .real(value) }
    /// Wraps a `String` as ``text(_:)``.
    public init(_ value: String) { self = .text(value) }
    /// Wraps bytes as ``blob(_:)``.
    public init(_ value: [UInt8]) { self = .blob(value) }
    /// Wraps an optional value, mapping `nil` to ``null``.
    public init(_ value: SQLiteValue?) { self = value ?? .null }
}

/// One result row.
public struct SQLiteRow: Sendable, Hashable, RandomAccessCollection {
    /// The column names, shared by all rows of a result.
    public let columnNames: [String]
    /// The column values in result order.
    public let values: [SQLiteValue]

    public init(columnNames: [String], values: [SQLiteValue]) {
        self.columnNames = columnNames
        self.values = values
    }

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public subscript(position: Int) -> SQLiteValue { values[position] }

    /// The value of the first column with this name, or `nil` if there is none.
    public subscript(name: String) -> SQLiteValue? {
        columnNames.firstIndex(of: name).map { values[$0] }
    }

    /// The integer in column `index`.
    public func integer(_ index: Int) throws(SQLiteError) -> Int64 {
        guard case .integer(let v) = try value(index) else { throw mismatch(index, .integer) }
        return v
    }

    /// The integer in column `index`, or `nil` if the column is NULL.
    public func optionalInteger(_ index: Int) throws(SQLiteError) -> Int64? {
        if case .null = try value(index) { return nil }
        return try integer(index)
    }

    /// The real number in column `index`. Integers are converted.
    public func real(_ index: Int) throws(SQLiteError) -> Double {
        switch try value(index) {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: throw mismatch(index, .real)
        }
    }

    /// The text in column `index`.
    public func text(_ index: Int) throws(SQLiteError) -> String {
        guard case .text(let v) = try value(index) else { throw mismatch(index, .text) }
        return v
    }

    /// The text in column `index`, or `nil` if the column is NULL.
    public func optionalText(_ index: Int) throws(SQLiteError) -> String? {
        if case .null = try value(index) { return nil }
        return try text(index)
    }

    /// The bytes in column `index`.
    public func blob(_ index: Int) throws(SQLiteError) -> [UInt8] {
        guard case .blob(let v) = try value(index) else { throw mismatch(index, .blob) }
        return v
    }

    /// The bytes in column `index`, or `nil` if the column is NULL.
    public func optionalBlob(_ index: Int) throws(SQLiteError) -> [UInt8]? {
        if case .null = try value(index) { return nil }
        return try blob(index)
    }

    private func value(_ index: Int) throws(SQLiteError) -> SQLiteValue {
        guard values.indices.contains(index) else {
            throw .invalidArgument("column index \(index) out of range 0..<\(values.count)")
        }
        return values[index]
    }

    private func mismatch(_ index: Int, _ expected: SQLiteValueKind) -> SQLiteError {
        .typeMismatch(column: index, expected: expected, actual: values[index].kind)
    }
}

/// The effect of one executed statement.
public struct SQLiteChanges: Sendable, Hashable {
    /// Rows changed by the statement (`sqlite3_changes64`).
    public var changedRows: Int
    /// The connection's last inserted rowid (`sqlite3_last_insert_rowid`).
    public var lastInsertRowID: Int64

    public init(changedRows: Int, lastInsertRowID: Int64) {
        self.changedRows = changedRows
        self.lastInsertRowID = lastInsertRowID
    }
}
