// SPDX-License-Identifier: Apache-2.0

/// A SQLite value with its exact bytes.
///
/// ``SQLiteValue/text(_:)`` decodes TEXT into a Swift `String`, which replaces invalid
/// UTF-8 and so can change the bytes. ``SQLiteRawValue/text(_:)`` keeps the stored
/// bytes exactly as SQLite returns them, including invalid UTF-8 and embedded NUL
/// bytes. Use raw values where bytes must round-trip unchanged, for example
/// canonical JSON or content hashes. Read them with
/// ``SQLiteTransaction/queryRaw(_:_:limits:)`` and write them with
/// ``SQLiteTransaction/executeRaw(_:_:)``.
///
/// The five cases are SQLite's storage classes; no case will be added.
public enum SQLiteRawValue: Sendable, Hashable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    /// TEXT, as the stored bytes.
    case text([UInt8])
    case blob([UInt8])

    /// The raw form of a value: text becomes its UTF-8 bytes.
    public init(_ value: SQLiteValue) {
        switch value {
        case .null: self = .null
        case .integer(let v): self = .integer(v)
        case .real(let v): self = .real(v)
        case .text(let s): self = .text(Array(s.utf8))
        case .blob(let b): self = .blob(b)
        }
    }

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

    /// The number of bytes this value counts against a result budget (integers and
    /// reals count as 8).
    public var byteCount: Int {
        switch self {
        case .null: 0
        case .integer, .real: 8
        case .text(let b), .blob(let b): b.count
        }
    }

    public var description: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .text(let b): "TEXT(\(b.count) bytes)"
        case .blob(let b): "BLOB(\(b.count) bytes)"
        }
    }
}

/// One result row of ``SQLiteTransaction/queryRaw(_:_:limits:)``.
public struct SQLiteRawRow: Sendable, Hashable, RandomAccessCollection {
    /// The column names, shared by all rows of a result.
    public let columnNames: [String]
    /// The column values in result order.
    public let values: [SQLiteRawValue]

    public init(columnNames: [String], values: [SQLiteRawValue]) {
        self.columnNames = columnNames
        self.values = values
    }

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public subscript(position: Int) -> SQLiteRawValue { values[position] }

    /// The value of the first column with this name, or `nil` if there is none.
    public subscript(name: String) -> SQLiteRawValue? {
        columnNames.firstIndex(of: name).map { values[$0] }
    }

    /// The integer in column `index`.
    public func integer(_ index: Int) throws(SQLiteError) -> Int64 {
        guard case .integer(let v) = try value(index) else { throw mismatch(index, .integer) }
        return v
    }

    /// The stored bytes of a TEXT or BLOB column, or `nil` if the column is NULL.
    public func bytes(_ index: Int) throws(SQLiteError) -> [UInt8]? {
        switch try value(index) {
        case .null: return nil
        case .text(let b), .blob(let b): return b
        default: throw mismatch(index, .blob)
        }
    }

    private func value(_ index: Int) throws(SQLiteError) -> SQLiteRawValue {
        guard values.indices.contains(index) else {
            throw .invalidArgument("column index \(index) out of range 0..<\(values.count)")
        }
        return values[index]
    }

    private func mismatch(_ index: Int, _ expected: SQLiteValueKind) -> SQLiteError {
        .typeMismatch(column: index, expected: expected, actual: values[index].kind)
    }
}
