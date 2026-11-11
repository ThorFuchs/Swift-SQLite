// SPDX-License-Identifier: Apache-2.0

import SwiftSQLite
import SwiftSQLiteTesting
import Testing

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

/// A small sample schema used across suites.
let sampleMigrations: [SQLiteMigration] = [
    SQLiteMigration(version: 1, name: "items", sql: """
        CREATE TABLE items (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            version INTEGER NOT NULL DEFAULT 1,
            payload BLOB,
            expires_at INTEGER
        );
        """),
    SQLiteMigration(version: 2, name: "tags") { (tx) throws(SQLiteError) in
        try tx.execute("CREATE TABLE tags (item_id INTEGER NOT NULL REFERENCES items(id), tag TEXT NOT NULL)")
    },
    SQLiteMigration(version: 3, name: "index", sql: "CREATE INDEX tags_by_item ON tags(item_id);"),
]

/// Opens a database in a fresh temporary directory, runs `body`, then closes it.
func withDatabase<T>(
    migrations: [SQLiteMigration] = sampleMigrations,
    configure: (inout SQLiteConfiguration) -> Void = { _ in },
    _ body: (SQLiteDatabase, SQLiteTemporaryDirectory) async throws -> T
) async throws -> T {
    let directory = try SQLiteTemporaryDirectory()
    var configuration = SQLiteConfiguration(path: directory.file("test.sqlite"))
    configure(&configuration)
    let database = try await SQLiteDatabase.open(configuration, migrations: migrations)
    do {
        let result = try await body(database, directory)
        await database.close()
        return result
    } catch {
        await database.close()
        throw error
    }
}
