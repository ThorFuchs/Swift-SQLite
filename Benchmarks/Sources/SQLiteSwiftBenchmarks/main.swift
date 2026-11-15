// SPDX-License-Identifier: Apache-2.0
// A small, dependency-free benchmark suite. Each case runs a warm-up and then
// `rounds` measured rounds on a fresh file database (WAL, synchronous=FULL, the
// defaults) and reports the median and the spread. Numbers are a baseline for this
// machine, not a promise.
import Foundation
import SQLiteSwift
import SQLiteSwiftModels

struct Result: Encodable {
    let name: String
    let operations: Int
    let medianMilliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
    var operationsPerSecond: Double { Double(operations) / (medianMilliseconds / 1000) }

    enum CodingKeys: String, CodingKey {
        case name, operations, medianMilliseconds, minMilliseconds, maxMilliseconds, operationsPerSecond
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(operations, forKey: .operations)
        try c.encode(medianMilliseconds, forKey: .medianMilliseconds)
        try c.encode(minMilliseconds, forKey: .minMilliseconds)
        try c.encode(maxMilliseconds, forKey: .maxMilliseconds)
        try c.encode(operationsPerSecond.rounded(), forKey: .operationsPerSecond)
    }
}

let migrations = [
    SQLiteMigration(version: 1, name: "bench", sql: """
        CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1, body BLOB NOT NULL);
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, title TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 1), incarnation BLOB NOT NULL);
        """),
    SQLiteModelSchema.migration(version: 2),
]

struct Note: SQLiteRecord {
    var id: String
    var title: String
    static let idColumn = SQLiteColumn("id", \Note.id, .text)
    static let titleColumn = SQLiteColumn("title", \Note.title, .text)
    static let descriptor = SQLiteRecordDescriptor(table: "notes", key: idColumn, columns: titleColumn) { row throws(SQLiteError) in
        Note(id: try row.value(idColumn), title: try row.value(titleColumn))
    }
}

let body = [UInt8](repeating: 0x5A, count: 256)

func withDatabase<T>(_ seedRows: Int, _ body: (SQLiteDatabase) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqliteswift-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await SQLiteDatabase.open(
        SQLiteConfiguration(path: directory.appendingPathComponent("bench.sqlite").path), migrations: migrations)
    if seedRows > 0 {
        let payload = Main.payload
        try await database.write { tx throws(SQLiteError) in
            for i in 0..<seedRows {
                try tx.execute("INSERT INTO items (id, name, body) VALUES (?, ?, ?)", [.integer(Int64(i)), .text("item \(i)"), .blob(payload)])
            }
        }
    }
    let result = try await body(database)
    await database.close()
    return result
}

func measure(_ name: String, operations: Int, rounds: Int = 5, seedRows: Int = 0,
             _ work: @escaping (SQLiteDatabase) async throws -> Void) async throws -> Result {
    var samples: [Double] = []
    for round in 0...rounds {  // round 0 is the warm-up
        let elapsed = try await withDatabase(seedRows) { database in
            let clock = ContinuousClock()
            let start = clock.now
            try await work(database)
            return start.duration(to: clock.now)
        }
        if round > 0 {
            let c = elapsed.components
            samples.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
        }
    }
    samples.sort()
    let result = Result(name: name, operations: operations, medianMilliseconds: samples[samples.count / 2],
                        minMilliseconds: samples.first!, maxMilliseconds: samples.last!)
    let line = name.padding(toLength: 40, withPad: " ", startingAt: 0)
        + String(format: "%10.0f ops/s  (median %.1f ms, min %.1f, max %.1f)\n",
                 result.operationsPerSecond, result.medianMilliseconds, result.minMilliseconds, result.maxMilliseconds)
    FileHandle.standardError.write(Data(line.utf8))
    return result
}

enum Main {
    static let payload = body
}

var results: [Result] = []

// Durable single-row commits: one transaction (and fsync) per insert.
results.append(try await measure("write: 500 single-row transactions", operations: 500) { db in
    for i in 0..<500 {
        try await db.write { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO items (id, name, body) VALUES (?, ?, ?)", [.integer(Int64(i)), .text("item"), .blob(Main.payload)])
        }
    }
})

// Bulk insert in one transaction (statement cache, bound values).
results.append(try await measure("write: 50,000 rows in one transaction", operations: 50_000) { db in
    try await db.write { tx throws(SQLiteError) in
        for i in 0..<50_000 {
            try tx.execute("INSERT INTO items (id, name, body) VALUES (?, ?, ?)", [.integer(Int64(i)), .text("item"), .blob(Main.payload)])
        }
    }
})

// Point reads, one read transaction each, from 8 concurrent tasks over the reader pool.
results.append(try await measure("read: 20,000 point reads, 8 tasks", operations: 20_000, seedRows: 10_000) { db in
    try await withThrowingTaskGroup(of: Void.self) { group in
        for task in 0..<8 {
            group.addTask {
                for i in 0..<2_500 {
                    let key = Int64((task * 2_500 + i) % 10_000)
                    _ = try await db.read { tx throws(SQLiteError) in
                        try tx.queryOne("SELECT name FROM items WHERE id = ?", [.integer(key)])
                    }
                }
            }
        }
        try await group.waitForAll()
    }
})

// Keyset paging through 10,000 rows, 500 per page.
results.append(try await measure("read: keyset scan of 10,000 rows", operations: 10_000, seedRows: 10_000) { db in
    var cursor: SQLiteKeysetCursor?
    var seen = 0
    repeat {
        let page = try await db.read { [cursor] tx throws(SQLiteError) in
            try tx.queryPage(table: "items", columns: ["id", "name"], keyColumns: ["id"], after: cursor, limit: 500)
        }
        seen += page.rows.count
        cursor = page.nextCursor
    } while cursor != nil
    precondition(seen == 10_000)
})

// Compare-and-set updates, one transaction each.
results.append(try await measure("write: 500 compare-and-set updates", operations: 500, seedRows: 1) { db in
    for version in 1...500 {
        let result = try await db.write { tx throws(SQLiteError) in
            try tx.compareAndSet(table: "items", id: .integer(0), expectedVersion: Int64(version),
                                 assignments: [SQLiteAssignment("name", .text("v\(version)"))])
        }
        precondition(result == .updated(newVersion: Int64(version) + 1))
    }
})

// Model layer: managed batches through a store (sequence, change publication).
results.append(try await measure("model: 200 batches of 10 inserts", operations: 2_000) { db in
    let store = SQLiteModelStore(database: db)
    for batch in 0..<200 {
        let writes = (0..<10).map { i in SQLiteRecordWrite.insert(Note(id: "n\(batch)-\(i)", title: "t")) }
        guard case .committed = try await store.writeRecords(writes) else { preconditionFailure("conflict") }
    }
})

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(results), as: UTF8.self))
