// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModels
import Testing

@Suite("G1: record descriptors, codecs and snapshots")
struct RecordTests {
    let article = Article(id: "a1", title: "Hello", summary: nil, featured: true, status: .published)
    let reading = Reading(id: 42, value: 21.5, takenAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                          count: 7, note: "calibrated")
    let attachment = Attachment(
        id: UUID(uuidString: "6F1C2E58-0B7A-4D4E-9C55-2A1B3C4D5E6F")!, name: "scan.pdf",
        bytes: [0, 1, 2, 255], price: Decimal(string: "12.5")!,
        owner: UUID(uuidString: "abcdef00-0000-4000-8000-00000000000a")!,
        created: SQLiteTimestamp(millisecondsSince1970: 1_700_000_000_000))

    @Test("Three different record types round-trip with a version")
    func roundTrip() async throws {
        try await withRecordDatabase { database in
            let (a, r, t) = (article, reading, attachment)
            try await database.write { (tx) throws(SQLiteError) in
                try insertRaw(a, in: tx)
                try insertRaw(r, in: tx)
                try insertRaw(t, in: tx)
            }
            let snapshots = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetch(Article.self, id: "a1"), try tx.fetch(Reading.self, id: 42),
                 try tx.fetch(Attachment.self, id: t.id))
            }
            #expect(snapshots.0?.value == a)
            #expect(snapshots.1?.value == r)
            #expect(snapshots.2?.value == t)
            for version in [snapshots.0?.version, snapshots.1?.version, snapshots.2?.version] {
                #expect(version?.revision == 1)
                #expect(version?.incarnation.count == 16)
            }
            #expect(snapshots.0?.version.incarnation != snapshots.1?.version.incarnation)
        }
    }

    @Test("A missing key reads as nil; nil optionals are stored as SQL NULL")
    func missingAndNull() async throws {
        try await withRecordDatabase { database in
            let a = article
            try await database.write { (tx) throws(SQLiteError) in try insertRaw(a, in: tx) }
            let (missing, storedNull) = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetch(Article.self, id: "nope"),
                 try tx.scalar("SELECT typeof(summary) FROM articles WHERE id = 'a1'"))
            }
            #expect(missing == nil)
            #expect(storedNull == .text("null"))
        }
    }

    @Test("Values a codec can't decode are refused, naming the column", arguments: [
        ("UPDATE articles SET title = NULL", "title"),
        ("UPDATE articles SET title = CAST(x'ff' AS TEXT)", "title"),
        ("UPDATE articles SET title = 12", "title"),
        ("UPDATE articles SET featured = 2", "featured"),
        ("UPDATE articles SET status = 'archived'", "status"),
        ("UPDATE articles SET revision = 0", "revision"),
        ("UPDATE articles SET incarnation = x'0102'", "incarnation"),
        ("UPDATE articles SET incarnation = NULL", "incarnation"),
    ])
    func invalidArticle(sql: String, column: String) async throws {
        try await withRecordDatabase { database in
            let a = article
            try await database.write { (tx) throws(SQLiteError) in
                try insertRaw(a, in: tx)
                try tx.execute(sql)
            }
            let error = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a1") }
            }
            #expect(error?.code == .invalidStoredValue)
            #expect(error?.column == column, "\(String(describing: error))")
        }
    }

    @Test("Numeric, time and identifier codecs refuse what they can't represent", arguments: [
        ("readings", "UPDATE readings SET value = 'x'", "value"),
        ("readings", "UPDATE readings SET taken_at = 1.5", "taken_at"),
        ("readings", "UPDATE readings SET count = 'seven'", "count"),
        ("attachments", "UPDATE attachments SET price = '12.50'", "price"),
        ("attachments", "UPDATE attachments SET price = 'twelve'", "price"),
        ("attachments", "UPDATE attachments SET owner = upper(owner)", "owner"),
        ("attachments", "UPDATE attachments SET created = NULL", "created"),
    ])
    func invalidOthers(table: String, sql: String, column: String) async throws {
        try await withRecordDatabase { database in
            let (r, t) = (reading, attachment)
            try await database.write { (tx) throws(SQLiteError) in
                try insertRaw(r, in: tx)
                try insertRaw(t, in: tx)
                try tx.execute(sql)
            }
            let error = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    table == "readings"
                        ? try tx.fetch(Reading.self, id: 42).map { _ in () }
                        : try tx.fetch(Attachment.self, id: t.id).map { _ in () }
                }
            }
            #expect(error?.code == .invalidStoredValue)
            #expect(error?.column == column, "\(String(describing: error))")
        }
    }

    @Test("A UUID key stored with the wrong length is refused on fetchAll")
    func badUUIDKey() async throws {
        try await withRecordDatabase { database in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("""
                    INSERT INTO attachments VALUES (x'0102', 'n', x'', NULL,
                      '00000000-0000-4000-8000-000000000001', 0, 1, randomblob(16))
                    """)
            }
            let error = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.fetchAll(Attachment.self) }
            }
            #expect(error?.code == .invalidStoredValue)
            #expect(error?.column == "id")
        }
    }

    @Test("fetchAll filters, orders by key and never truncates")
    func fetchAll() async throws {
        try await withRecordDatabase { database in
            try await database.write { (tx) throws(SQLiteError) in
                for id in [3, 1, 2] as [Int64] {
                    try insertRaw(Reading(id: id, value: Double(id), takenAt: Date(timeIntervalSince1970: 0),
                                          count: Int(id), note: nil), in: tx)
                }
            }
            let ids = try await database.read { (tx) throws(SQLiteError) in
                try tx.fetchAll(Reading.self).map(\.value.id)
            }
            #expect(ids == [1, 2, 3])
            let filtered = try await database.read { (tx) throws(SQLiteError) in
                try tx.fetchAll(Reading.self, where: .greaterThanOrEqual("count", 2)).map(\.value.id)
            }
            #expect(filtered == [2, 3])
            let tooMany = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.fetchAll(Reading.self, limits: SQLiteQueryLimits(maxRows: 2))
                }
            }
            #expect(tooMany?.code == .rowLimitExceeded)
        }
    }

    @Test("verifySchema reports a missing table or column")
    func schema() async throws {
        try await withRecordDatabase { database in
            try await database.read { (tx) throws(SQLiteError) in
                try tx.verifySchema(for: Article.self)
                try tx.verifySchema(for: Reading.self)
                try tx.verifySchema(for: Attachment.self)
            }
            let noTable = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.verifySchema(for: Ghost.self) } }
            #expect(noTable?.code == .schemaMismatch)
            #expect(noTable?.setting?.name == "ghosts")
            let noColumn = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.verifySchema(for: Incomplete.self) } }
            #expect(noColumn?.code == .schemaMismatch)
            #expect(noColumn?.setting?.name == "incomplete.revision")
        }
    }

    @Test("Invalid descriptors are refused before any SQL runs")
    func invalidDescriptors() async throws {
        #expect(throws: SQLiteError.self) { try Duplicate.descriptor.validate() }
        #expect(throws: SQLiteError.self) { try Managed.descriptor.validate() }
        try await withRecordDatabase { database in
            let error = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Managed.self, id: "x") }
            }
            #expect(error?.code == .invalidConfiguration)
        }
    }

    @Test("Codecs: exact conversions only")
    func codecs() throws {
        #expect(try SQLiteCodec.real.decode(.integer(3), column: "c") == 3.0)
        #expect(throws: SQLiteError.self) { try SQLiteCodec.real.decode(.integer(Int64.max), column: "c") }
        #expect(throws: SQLiteError.self) { try SQLiteCodec.real.encode(.nan) }
        let ms = Date(timeIntervalSince1970: 1_700_000_000.123)
        #expect(try SQLiteCodec.unixMilliseconds.encode(ms) == .integer(1_700_000_000_123))
        #expect(throws: SQLiteError.self) {
            try SQLiteCodec.unixMilliseconds.encode(Date(timeIntervalSince1970: 1.0000001))
        }
        let uuid = UUID()
        #expect(try SQLiteCodec.uuidBlob.decode(SQLiteCodec.uuidBlob.encode(uuid), column: "c") == uuid)
        #expect(try SQLiteCodec.uuidText.decode(SQLiteCodec.uuidText.encode(uuid), column: "c") == uuid)
        let price = Decimal(string: "0.1")!
        #expect(try SQLiteCodec.decimalText.encode(price) == .text(Array("0.1".utf8)))
        #expect(try SQLiteCodec.decimalText.decode(.text(Array("0.1".utf8)), column: "c") == price)
        #expect(try SQLiteCodec.optional(SQLiteCodec<Int>.int).decode(.null, column: "c") == nil)
        #expect(try SQLiteCodec.optional(SQLiteCodec<Int>.int).encode(nil) == .null)
        #expect(SQLiteCodec<String?>.optional(.text).storage == "TEXT (UTF-8) or NULL")
        let stored = try Article.descriptor.encode(article)
        #expect(stored.count == Article.descriptor.columnNames.count)
        #expect(Article.descriptor.columnNames == ["id", "title", "summary", "featured", "status"])
        #expect(throws: SQLiteError.self) { try SQLiteRecordVersion(revision: 0, incarnation: Array(repeating: 0, count: 16)) }
        #expect(throws: SQLiteError.self) { try SQLiteRecordVersion(revision: 1, incarnation: [1]) }
    }

    @Test("Snapshots are Sendable values that cross tasks")
    func sendableSnapshots() async throws {
        try await withRecordDatabase { database in
            let a = article
            try await database.write { (tx) throws(SQLiteError) in try insertRaw(a, in: tx) }
            let snapshot = try #require(try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a1") })
            let copy = await Task.detached { snapshot }.value
            #expect(copy == snapshot)
            #expect(copy.version.description.hasPrefix("r1/"))
        }
    }
}

// Record types used by single tests. Key paths into function-local types fail at
// run time, so they live at file scope.
struct Ghost: SQLiteRecord {
    var id: String
    static let idColumn = SQLiteColumn("id", \Ghost.id, .text)
    static let descriptor = SQLiteRecordDescriptor(table: "ghosts", key: idColumn) { row throws(SQLiteError) in
        Ghost(id: try row.value(idColumn))
    }
}

struct Incomplete: SQLiteRecord {
    var id: String
    var title: String
    static let idColumn = SQLiteColumn("id", \Incomplete.id, .text)
    static let titleColumn = SQLiteColumn("title", \Incomplete.title, .text)
    static let descriptor = SQLiteRecordDescriptor(table: "incomplete", key: idColumn, columns: titleColumn) {
        row throws(SQLiteError) in Incomplete(id: try row.value(idColumn), title: try row.value(titleColumn))
    }
}

struct Duplicate: SQLiteRecord {
    var id: String
    var other: String
    static let idColumn = SQLiteColumn("id", \Duplicate.id, .text)
    static let otherColumn = SQLiteColumn("id", \Duplicate.other, .text)
    static let descriptor = SQLiteRecordDescriptor(table: "articles", key: idColumn, columns: otherColumn) {
        row throws(SQLiteError) in Duplicate(id: try row.value(idColumn), other: try row.value(otherColumn))
    }
}

struct Managed: SQLiteRecord {
    var id: String
    var revision: Int64
    static let idColumn = SQLiteColumn("id", \Managed.id, .text)
    static let revisionColumn = SQLiteColumn("revision", \Managed.revision, .integer)
    static let descriptor = SQLiteRecordDescriptor(table: "articles", key: idColumn, columns: revisionColumn) {
        row throws(SQLiteError) in Managed(id: try row.value(idColumn), revision: try row.value(revisionColumn))
    }
}
