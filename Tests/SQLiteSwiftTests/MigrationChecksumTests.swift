// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing

@Suite("Migration checksums")
struct MigrationChecksumTests {
    let v1 = SQLiteMigration(version: 1, name: "items", sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);")
    let v2 = SQLiteMigration(version: 2, name: "index", sql: "CREATE INDEX items_name ON items(name);")
    let v3 = SQLiteMigration(version: 3, name: "tags") { (tx) throws(SQLiteError) in
        try tx.execute("CREATE TABLE tags (item_id INTEGER, tag TEXT)")
    }

    private func open(_ path: String, _ migrations: [SQLiteMigration], verify: Bool) async throws -> SQLiteDatabase {
        var configuration = SQLiteConfiguration(path: path)
        configuration.verifiesMigrationChecksums = verify
        return try await SQLiteDatabase.open(configuration, migrations: migrations)
    }

    private func checksums(_ database: SQLiteDatabase) async throws -> [Int64: String] {
        try await database.read { (tx) throws(SQLiteError) -> [Int64: String] in
            var result: [Int64: String] = [:]
            for row in try tx.query("SELECT version, checksum FROM sqliteswift_migration_checksums") {
                result[try row.integer(0)] = try row.text(1)
            }
            return result
        }
    }

    /// Opens with exactly `migrations`: if a later migration had run, this would throw
    /// `schemaTooNew`.
    private func userVersion(_ path: String, _ migrations: [SQLiteMigration]) async throws -> SQLiteValue? {
        let database = try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: migrations)
        defer { Task { await database.close() } }
        return try await database.read { (tx) throws(SQLiteError) in try tx.scalar("PRAGMA user_version") }
    }

    @Test("Checksums are stable: a fixed fingerprint per version, name and SQL")
    func stableFingerprint() {
        #expect(v1.checksum == "b4035cc676ab4874")  // FNV-1a 64, computed independently
        #expect(v1.checksum.count == 16)
        let edited = SQLiteMigration(version: 1, name: "items", sql: "CREATE TABLE items (id INTEGER PRIMARY KEY);")
        #expect(edited.checksum != v1.checksum)
        let renamed = SQLiteMigration(version: 3, name: "tags v2") { (_) throws(SQLiteError) in }
        #expect(renamed.checksum != v3.checksum)
    }

    @Test("Off by default: no table, nothing checked")
    func offByDefault() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await open(directory.file("a.sqlite"), [v1, v2], verify: false)
        let table = try await database.read { (tx) throws(SQLiteError) in
            try tx.queryOne("SELECT 1 FROM sqlite_schema WHERE name = 'sqliteswift_migration_checksums'")
        }
        #expect(table == nil)
        await database.close()
    }

    @Test("On: every applied migration is recorded, and a reopen passes")
    func recordsAndPasses() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("b.sqlite")
        let first = try await open(path, [v1, v2, v3], verify: true)
        #expect(try await checksums(first) == [1: v1.checksum, 2: v2.checksum, 3: v3.checksum])
        await first.close()
        let again = try await open(path, [v1, v2, v3], verify: true)
        await again.close()
    }

    @Test("An edited shipped migration is refused before any new migration runs")
    func editedMigrationRefused() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("c.sqlite")
        await (try await open(path, [v1, v2], verify: true)).close()

        let edited = SQLiteMigration(version: 2, name: "index", sql: "CREATE INDEX items_name ON items(name, id);")
        let error = await caught { try await open(path, [v1, edited, v3], verify: true) }
        #expect(error?.code == .migrationModified)
        #expect(error?.description.contains("migration 2 (index)") == true)
        #expect(try await userVersion(path, [v1, v2]) == .integer(2))  // v3 did not run
    }

    @Test("Existing files and later activation are adopted, then protected")
    func adoption() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("d.sqlite")
        await (try await open(path, [v1, v2], verify: false)).close()
        let adopted = try await open(path, [v1, v2, v3], verify: true)
        #expect(try await checksums(adopted) == [1: v1.checksum, 2: v2.checksum, 3: v3.checksum])
        await adopted.close()

        let renamed = SQLiteMigration(version: 3, name: "tags renamed") { (tx) throws(SQLiteError) in
            try tx.execute("CREATE TABLE tags (item_id INTEGER, tag TEXT)")
        }
        let error = await caught { try await open(path, [v1, v2, renamed], verify: true) }
        #expect(error?.code == .migrationModified)
    }
}
