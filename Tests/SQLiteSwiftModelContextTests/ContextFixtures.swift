// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModelContext
import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

struct Note: SQLiteRecord {
    var id: String
    var title: String
    var body: String?

    static let idColumn = SQLiteColumn("id", \Note.id, .text)
    static let titleColumn = SQLiteColumn("title", \Note.title, .text)
    static let bodyColumn = SQLiteColumn("body", \Note.body, .optional(.text))

    static let descriptor = SQLiteRecordDescriptor(
        table: "notes", key: idColumn, columns: titleColumn, bodyColumn
    ) { row throws(SQLiteError) in
        Note(id: try row.value(idColumn), title: try row.value(titleColumn), body: try row.value(bodyColumn))
    }
}

struct Counter: SQLiteRecord {
    var id: Int64
    var count: Int

    static let idColumn = SQLiteColumn("id", \Counter.id, .integer)
    static let countColumn = SQLiteColumn("count", \Counter.count, .int)

    static let descriptor = SQLiteRecordDescriptor(
        table: "counters", key: idColumn, columns: countColumn
    ) { row throws(SQLiteError) in
        Counter(id: try row.value(idColumn), count: try row.value(countColumn))
    }
}

let contextMigrations = [
    SQLiteMigration(version: 1, name: "records", sql: """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT,
            revision INTEGER NOT NULL CHECK (revision >= 1), incarnation BLOB NOT NULL);
        CREATE TABLE counters (
            id INTEGER PRIMARY KEY, count INTEGER NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 1), incarnation BLOB NOT NULL);
        """),
    SQLiteModelSchema.migration(version: 2),
]

/// A file database seeded with notes "a" and "b" and counter 1.
@MainActor
func withContextDatabase<T>(_ body: @MainActor (SQLiteDatabase) async throws -> T) async throws -> T {
    let directory = try SQLiteTemporaryDirectory()
    let database = try await SQLiteDatabase.open(
        SQLiteConfiguration(path: directory.file("context.sqlite")), migrations: contextMigrations)
    do {
        try await database.writeRecords([
            .insert(Note(id: "a", title: "A", body: nil)),
            .insert(Note(id: "b", title: "B", body: "bee")),
            .insert(Counter(id: 1, count: 0)),
        ])
        let result = try await body(database)
        await database.close()
        return result
    } catch {
        await database.close()
        throw error
    }
}

func stored(_ database: SQLiteDatabase, note id: String) async throws -> SQLiteRecordSnapshot<Note>? {
    try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Note.self, id: id) }
}

func markerCount(_ database: SQLiteDatabase) async throws -> SQLiteValue? {
    try await database.read { (tx) throws(SQLiteError) in
        try tx.scalar("SELECT count(*) FROM \(SQLiteModelSchema.operationsTable)")
    }
}

/// Runs `operation` and returns the SQLiteError it threw, or `nil`.
@MainActor
func caught<T>(_ operation: @MainActor () async throws -> T) async -> SQLiteError? {
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

/// A one-shot barrier: `wait()` suspends until `open()`. No sleeping, no polling.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A Sendable signal from a worker thread to an async test.
final class Signal: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func fire() { continuation.yield() }

    func next() async {
        for await _ in stream { return }
    }
}
