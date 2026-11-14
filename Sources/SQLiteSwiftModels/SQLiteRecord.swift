// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// A plain value stored as one row of a table.
///
/// A record is a `Sendable`, `Equatable` struct with a stable ``id``. Its
/// ``descriptor`` says how it maps to a table: the key column, one
/// ``SQLiteColumn`` per stored field, and how to build the record from a row.
///
/// ```swift
/// struct Article: SQLiteRecord {
///     var id: String
///     var title: String
///     var summary: String?
///
///     static let idColumn = SQLiteColumn("id", \Article.id, .text)
///     static let titleColumn = SQLiteColumn("title", \Article.title, .text)
///     static let summaryColumn = SQLiteColumn("summary", \Article.summary, .optional(.text))
///
///     static let descriptor = SQLiteRecordDescriptor(
///         table: "articles", key: idColumn, columns: titleColumn, summaryColumn
///     ) { row throws(SQLiteError) in
///         Article(id: try row.value(idColumn), title: try row.value(titleColumn),
///                 summary: try row.value(summaryColumn))
///     }
/// }
/// ```
///
/// The table also has two columns the model layer manages: a revision and an
/// incarnation (see ``SQLiteRecordVersion``). Declare them in your migration:
/// `revision INTEGER NOT NULL CHECK (revision >= 1), incarnation BLOB NOT NULL`.
public protocol SQLiteRecord: Sendable, Equatable {
    associatedtype ID: Hashable & Sendable
    /// The record's key. It identifies the row together with the incarnation.
    var id: ID { get }
    /// How the record maps to its table.
    static var descriptor: SQLiteRecordDescriptor<Self> { get }
}

/// One stored field of a record: a column name, the property it reads, and a codec.
///
/// Pass the property as a key path literal: `SQLiteColumn("title", \Article.title, .text)`.
public struct SQLiteColumn<Record: SQLiteRecord, Value>: Sendable {
    /// The column name.
    public let name: String
    /// The codec that converts the property to and from its stored form.
    public let codec: SQLiteCodec<Value>
    // A plain function; a key path literal converts to it at the call site.
    let read: @Sendable (Record) -> Value

    public init(_ name: String, _ read: @escaping @Sendable (Record) -> Value, _ codec: SQLiteCodec<Value>) {
        self.name = name
        self.read = read
        self.codec = codec
    }

    /// Encodes this column's value of `record`.
    public func encode(_ record: Record) throws(SQLiteError) -> SQLiteRawValue {
        try codec.encode(read(record))
    }
}

/// A column with its value type erased, in descriptor order.
struct SQLiteAnyColumn<Record: SQLiteRecord>: Sendable {
    let name: String
    let storage: String
    let encode: @Sendable (Record) throws(SQLiteError) -> SQLiteRawValue

    init<Value>(_ column: SQLiteColumn<Record, Value>) {
        name = column.name
        storage = column.codec.storage
        encode = { (record) throws(SQLiteError) in try column.encode(record) }
    }
}

/// The values of one row, read by column while a record is built.
public struct SQLiteRecordRow<Record: SQLiteRecord> {
    let indexes: [String: Int]
    let values: [SQLiteRawValue]

    /// The decoded value of `column` in this row.
    public func value<Value>(_ column: SQLiteColumn<Record, Value>) throws(SQLiteError) -> Value {
        guard let index = indexes[column.name] else {
            throw .misuse("column \(column.name) is not part of the descriptor of \(Record.self)")
        }
        return try column.codec.decode(values[index], column: column.name)
    }
}

/// How a record maps to its table.
public struct SQLiteRecordDescriptor<Record: SQLiteRecord>: Sendable {
    /// The table.
    public let table: SQLiteIdentifier
    /// The key column's name.
    public let keyColumn: String
    /// The managed revision column (default `revision`).
    public let revisionColumn: String
    /// The managed incarnation column (default `incarnation`).
    public let incarnationColumn: String
    /// The stored columns in order: the key first, then the fields.
    public let columnNames: [String]

    let keyCodec: SQLiteCodec<Record.ID>
    let columns: [SQLiteAnyColumn<Record>]
    let indexes: [String: Int]
    let build: @Sendable (SQLiteRecordRow<Record>) throws(SQLiteError) -> Record

    /// - Parameters:
    ///   - table: The table name.
    ///   - key: The key column; its key path must be `\.id`.
    ///   - columns: The other stored fields, in any order.
    ///   - revisionColumn: The managed revision column.
    ///   - incarnationColumn: The managed incarnation column.
    ///   - build: Builds a record from a row with ``SQLiteRecordRow/value(_:)``.
    public init<each Value>(
        table: SQLiteIdentifier,
        key: SQLiteColumn<Record, Record.ID>,
        columns: repeat SQLiteColumn<Record, each Value>,
        revisionColumn: String = "revision",
        incarnationColumn: String = "incarnation",
        build: @escaping @Sendable (SQLiteRecordRow<Record>) throws(SQLiteError) -> Record
    ) {
        var erased = [SQLiteAnyColumn(key)]
        repeat erased.append(SQLiteAnyColumn(each columns))
        self.table = table
        self.keyColumn = key.name
        self.keyCodec = key.codec
        self.revisionColumn = revisionColumn
        self.incarnationColumn = incarnationColumn
        self.columns = erased
        // A closure, not `\.name`: a key path into this generic type inside the
        // parameter-pack initializer crashes at run time in Swift 6.4
        // ("could not demangle keypath type").
        self.columnNames = erased.map { $0.name }
        var indexes: [String: Int] = [:]
        for (index, column) in erased.enumerated() where indexes[column.name] == nil {
            indexes[column.name] = index
        }
        self.indexes = indexes
        self.build = build
    }

    /// Checks the descriptor itself: non-empty, distinct column names that don't use
    /// the managed column names.
    public func validate() throws(SQLiteError) {
        _ = try table.quoted()
        let managed = [revisionColumn, incarnationColumn]
        guard Set(managed).count == 2 else {
            throw .invalidConfiguration("\(Record.self): the revision and incarnation columns must differ")
        }
        var seen = Set<String>()
        for name in columnNames + managed {
            _ = try SQLiteIdentifier(name).quoted()
            guard seen.insert(name).inserted else {
                throw .invalidConfiguration("\(Record.self): column \(name) appears more than once")
            }
        }
    }

    /// The stored values of `record`, in ``columnNames`` order. Use it for SQL you
    /// write yourself; managed writes go through the model layer.
    public func encode(_ record: Record) throws(SQLiteError) -> [SQLiteRawValue] {
        var values: [SQLiteRawValue] = []
        values.reserveCapacity(columns.count)
        for column in columns { values.append(try column.encode(record)) }
        return values
    }

    /// The stored form of a key.
    public func encodeKey(_ id: Record.ID) throws(SQLiteError) -> SQLiteRawValue {
        try keyCodec.encode(id)
    }

    /// Builds a record and its version from the stored columns followed by the
    /// revision and incarnation.
    func decode(_ values: [SQLiteRawValue]) throws(SQLiteError) -> SQLiteRecordSnapshot<Record> {
        let fieldCount = columns.count
        guard values.count == fieldCount + 2 else {
            throw .misuse("expected \(fieldCount + 2) values for \(Record.self), got \(values.count)")
        }
        let record = try build(SQLiteRecordRow(indexes: indexes, values: Array(values[0..<fieldCount])))
        let version = try SQLiteRecordVersion(
            stored: values[fieldCount], incarnation: values[fieldCount + 1],
            revisionColumn: revisionColumn, incarnationColumn: incarnationColumn)
        return SQLiteRecordSnapshot(value: record, version: version)
    }
}
