// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

// Three deliberately different records: text key with an enum and a Bool; integer key
// with REAL, a Date and an optional field; UUID BLOB key with bytes, a decimal, a
// UUID as text and a timestamp.

enum ArticleStatus: String, Sendable {
    case draft, published
}

struct Article: SQLiteRecord {
    var id: String
    var title: String
    var summary: String?
    var featured: Bool
    var status: ArticleStatus

    static let idColumn = SQLiteColumn("id", \Article.id, .text)
    static let titleColumn = SQLiteColumn("title", \Article.title, .text)
    static let summaryColumn = SQLiteColumn("summary", \Article.summary, .optional(.text))
    static let featuredColumn = SQLiteColumn("featured", \Article.featured, .bool)
    static let statusColumn = SQLiteColumn("status", \Article.status, .rawValue(.text))

    static let descriptor = SQLiteRecordDescriptor(
        table: "articles", key: idColumn,
        columns: titleColumn, summaryColumn, featuredColumn, statusColumn
    ) { row throws(SQLiteError) in
        Article(
            id: try row.value(idColumn), title: try row.value(titleColumn),
            summary: try row.value(summaryColumn), featured: try row.value(featuredColumn),
            status: try row.value(statusColumn))
    }
}

struct Reading: SQLiteRecord {
    var id: Int64
    var value: Double
    var takenAt: Date
    var count: Int
    var note: String?

    static let idColumn = SQLiteColumn("id", \Reading.id, .integer)
    static let valueColumn = SQLiteColumn("value", \Reading.value, .real)
    static let takenAtColumn = SQLiteColumn("taken_at", \Reading.takenAt, .unixMilliseconds)
    static let countColumn = SQLiteColumn("count", \Reading.count, .int)
    static let noteColumn = SQLiteColumn("note", \Reading.note, .optional(.text))

    static let descriptor = SQLiteRecordDescriptor(
        table: "readings", key: idColumn,
        columns: valueColumn, takenAtColumn, countColumn, noteColumn,
        revisionColumn: "rev", incarnationColumn: "inc"
    ) { row throws(SQLiteError) in
        Reading(
            id: try row.value(idColumn), value: try row.value(valueColumn),
            takenAt: try row.value(takenAtColumn), count: try row.value(countColumn),
            note: try row.value(noteColumn))
    }
}

struct Attachment: SQLiteRecord {
    var id: UUID
    var name: String
    var bytes: [UInt8]
    var price: Decimal?
    var owner: UUID
    var created: SQLiteTimestamp

    static let idColumn = SQLiteColumn("id", \Attachment.id, .uuidBlob)
    static let nameColumn = SQLiteColumn("name", \Attachment.name, .text)
    static let bytesColumn = SQLiteColumn("bytes", \Attachment.bytes, .blob)
    static let priceColumn = SQLiteColumn("price", \Attachment.price, .optional(.decimalText))
    static let ownerColumn = SQLiteColumn("owner", \Attachment.owner, .uuidText)
    static let createdColumn = SQLiteColumn("created", \Attachment.created, .timestamp)

    static let descriptor = SQLiteRecordDescriptor(
        table: "attachments", key: idColumn,
        columns: nameColumn, bytesColumn, priceColumn, ownerColumn, createdColumn
    ) { row throws(SQLiteError) in
        Attachment(
            id: try row.value(idColumn), name: try row.value(nameColumn),
            bytes: try row.value(bytesColumn), price: try row.value(priceColumn),
            owner: try row.value(ownerColumn), created: try row.value(createdColumn))
    }
}

/// Untyped columns, so tests can store values a codec must refuse.
let recordMigrations = [
    SQLiteMigration(version: 1, name: "records", sql: """
        CREATE TABLE articles (id, title, summary, featured, status, revision, incarnation);
        CREATE TABLE readings (id INTEGER PRIMARY KEY, value, taken_at, count, note, rev, inc);
        CREATE TABLE attachments (id PRIMARY KEY, name, bytes, price, owner, created, revision, incarnation);
        CREATE TABLE incomplete (id, title, featured, summary, status, incarnation);
        """)
]

/// Inserts a record with raw SQL built from its descriptor (revision 1, a fresh
/// incarnation). Managed inserts arrive in G2; this is the escape hatch.
func insertRaw<Record: SQLiteRecord>(_ record: Record, in tx: SQLiteTransaction) throws(SQLiteError) {
    let d = Record.descriptor
    let columns = d.columnNames + [d.revisionColumn, d.incarnationColumn]
    let placeholders = Array(repeating: "?", count: d.columnNames.count).joined(separator: ", ")
    let sql = "INSERT INTO \(d.table.name) (\(columns.joined(separator: ", "))) VALUES (\(placeholders), 1, randomblob(16))"
    try tx.executeRaw(sql, try d.encode(record))
}

func withRecordDatabase<T>(_ body: (SQLiteDatabase) async throws -> T) async throws -> T {
    let directory = try SQLiteTemporaryDirectory()
    let database = try await SQLiteDatabase.open(
        SQLiteConfiguration(path: directory.file("records.sqlite")), migrations: recordMigrations)
    do {
        let result = try await body(database)
        await database.close()
        return result
    } catch {
        await database.close()
        throw error
    }
}

/// Runs `operation` and returns the SQLiteError it threw, or `nil`.
func caught<T>(_ operation: () async throws -> T) async -> SQLiteError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as SQLiteError {
        return error
    } catch {
        Issue.record("unexpected non-SQLite error: \(error)")
        return nil
    }
}
