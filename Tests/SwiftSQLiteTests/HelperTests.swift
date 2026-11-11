// SPDX-License-Identifier: Apache-2.0

import SwiftSQLite
import SwiftSQLiteTesting
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Migrations, compare-and-set, expiry and checkpoints")
struct HelperTests {
    @Test("Migrations set user_version and run once each")
    func migrationsApply() async throws {
        try await withDatabase { database, directory in
            #expect(try await database.schemaVersion() == 3)
            #expect(database.supportedSchemaVersion == 3)
            let tables = try await database.read { (tx) throws(SQLiteError) in
                try tx.query("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name")
                    .map { (row) throws(SQLiteError) in try row.text(0) }
            }
            #expect(tables == ["items", "sqlite_autoindex_items_1", "tags", "tags_by_item"])
        }
    }

    @Test("A newer schema is refused without touching the file, also from a pending WAL")
    func schemaTooNew() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("future.sqlite")
        let future = try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: sampleMigrations)
        try await future.write { (tx) throws(SQLiteError) in try tx.execute("PRAGMA user_version = 7") }
        await future.close()
        let before = SQLiteCrashImage.contents(path)
        let error = await caught {
            try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: sampleMigrations)
        }
        #expect(error == .schemaTooNew(databaseVersion: 7, supportedVersion: 3))
        #expect(SQLiteCrashImage.contents(path) == before)
        #expect((SQLiteCrashImage.fileSize(path + "-wal") ?? 0) == 0)  // Apple keeps an empty WAL (persistent WAL)
    }

    @Test("A rollback-journal database newer than the code is not switched to WAL")
    func schemaTooNewKeepsJournalMode() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("legacy.sqlite")
        let memoryLike = try await SQLiteDatabase.open(SQLiteConfiguration.singleConnection(path: path), migrations: [])
        try await memoryLike.write { (tx) throws(SQLiteError) in
            try tx.execute("CREATE TABLE t (x)")
            try tx.execute("PRAGMA user_version = 9")
        }
        await memoryLike.close()
        // Rewrite the header's journal-mode bytes (offsets 18/19) back to rollback (1).
        var bytes = try #require(SQLiteCrashImage.contents(path))
        bytes[18] = 1
        bytes[19] = 1
        let file = fopen(path, "wb")!
        fwrite(bytes, 1, bytes.count, file)
        fclose(file)
        let error = await caught { try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: []) }
        #expect(error == .schemaTooNew(databaseVersion: 9, supportedVersion: 0))
        let after = try #require(SQLiteCrashImage.contents(path))
        #expect(after == bytes)
        #expect(after[18] == 1 && after[19] == 1)
    }

    @Test("Compare-and-set: updated, conflict, notFound; arguments validated")
    func compareAndSet() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (id, name, payload) VALUES (7, 'seven', x'00')")
            }
            let results = try await database.write { (tx) throws(SQLiteError) -> [SQLiteCompareAndSetResult] in
                [
                    try tx.compareAndSet(table: "items", id: 7, expectedVersion: 1,
                                         assignments: [SQLiteAssignment("payload", .blob([7]))]),
                    try tx.compareAndSet(table: "items", id: 7, expectedVersion: 1),
                    try tx.compareAndSet(table: "items", id: 8, expectedVersion: 1),
                    try tx.compareAndSet(table: "items", id: 7, expectedVersion: 2),
                ]
            }
            #expect(results == [.updated(newVersion: 2), .conflict(currentVersion: 2), .notFound, .updated(newVersion: 3)])
            let duplicate = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.compareAndSet(table: "items", id: 7, expectedVersion: 3,
                                         assignments: [SQLiteAssignment("version", 99)])
                }
            }
            guard case .invalidArgument = duplicate else { Issue.record("got \(String(describing: duplicate))"); return }
            let inRead = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.compareAndSet(table: "items", id: 7, expectedVersion: 3)
                }
            }
            guard case .readOnly = inRead else { Issue.record("got \(String(describing: inRead))"); return }
        }
    }

    @Test("A CAS conflict can roll back the rest of the transaction")
    func conflictRollsBack() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (id, name, version) VALUES (1, 'one', 5)")
            }
            let outcome = try await database.writeOrRollback { (tx) throws(SQLiteError) -> SQLiteTransactionOutcome<SQLiteCompareAndSetResult> in
                try tx.execute("INSERT INTO tags (item_id, tag) VALUES (1, 'side effect')")
                let result = try tx.compareAndSet(table: "items", id: 1, expectedVersion: 4)
                if case .updated = result { return .commit(result) }
                return .rollback(result)
            }
            #expect(outcome == .conflict(currentVersion: 5))
            let tags = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM tags") }
            #expect(tags == .integer(0))
        }
    }

    @Test("Expiry helpers use the injected clock only")
    func expiry() async throws {
        let clock = SQLiteManualClock(SQLiteTimestamp(millisecondsSince1970: 1_000_000))
        try await withDatabase(configure: { $0.clock = clock }) { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                #expect(tx.now() == SQLiteTimestamp(millisecondsSince1970: 1_000_000))
                for index in 0..<10 {
                    let deadline = tx.deadline(after: .seconds(Int64(index)))
                    try tx.execute("INSERT INTO items (name, expires_at) VALUES (?, ?)",
                                   [.text("e\(index)"), deadline.sqliteValue])
                }
                try tx.execute("INSERT INTO items (name, expires_at) VALUES ('forever', NULL)")
            }
            clock.advance(by: .milliseconds(4_500))
            let (expired, deletedFirst, deletedSecond) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.countExpired(in: "items", expiresAtColumn: "expires_at"),
                 try tx.deleteExpired(from: "items", expiresAtColumn: "expires_at", limit: 3),
                 try tx.deleteExpired(from: "items", expiresAtColumn: "expires_at", limit: 3))
            }
            #expect(expired == 5)  // deadlines +0s ... +4s
            #expect(deletedFirst == 3)
            #expect(deletedSecond == 2)
            clock.advance(by: .seconds(3600))
            let remaining = try await database.write { (tx) throws(SQLiteError) -> SQLiteValue? in
                try tx.deleteExpired(from: "items", expiresAtColumn: "expires_at", limit: 100)
                return try tx.scalar("SELECT group_concat(name) FROM items")
            }
            #expect(remaining == .text("forever"))
            let invalid = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.deleteExpired(from: "items", expiresAtColumn: "expires_at", limit: 0)
                }
            }
            guard case .invalidArgument = invalid else { Issue.record("got \(String(describing: invalid))"); return }
        }
    }

    @Test("Timestamps advance and saturate")
    func timestamps() {
        let base = SQLiteTimestamp(millisecondsSince1970: 1000)
        #expect(base.advanced(by: .milliseconds(1500)).millisecondsSince1970 == 2500)
        #expect(base.advanced(by: .seconds(-1)).millisecondsSince1970 == 0)
        #expect(SQLiteTimestamp(millisecondsSince1970: .max - 1).advanced(by: .seconds(10)).millisecondsSince1970 == .max)
        let system = SQLiteSystemClock().now().millisecondsSince1970
        #expect(system > 1_700_000_000_000)  // after 2023
    }

    @Test("Checkpoint modes report frames; a non-WAL database reports -1")
    func checkpoint() async throws {
        try await withDatabase { database, directory in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name, payload) VALUES ('c', zeroblob(10000))")
            }
            for mode in [SQLiteCheckpointMode.passive, .full, .restart, .truncate] {
                let result = try await database.checkpoint(mode)
                #expect(result.checkpointedFrames == result.walFrames)
            }
            #expect(SQLiteCrashImage.fileSize(directory.file("test.sqlite-wal")) == 0)
        }
        let memory = try await SQLiteDatabase.open(.inMemory(), migrations: sampleMigrations)
        let result = try await memory.checkpoint()
        await memory.close()
        #expect(result.walFrames == -1)
    }

    @Test("Migration failure carries version, name and the underlying typed error")
    func migrationFailure() async throws {
        let broken = sampleMigrations + [SQLiteMigration(version: 4, name: "broken", sql: "CREATE TABLE items (x);")]
        let directory = try SQLiteTemporaryDirectory()
        let error = await caught {
            try await SQLiteDatabase.open(SQLiteConfiguration(path: directory.file("m.sqlite")), migrations: broken)
        }
        guard case .migrationFailed(4, "broken", .sqlite(let details)) = error else {
            Issue.record("got \(String(describing: error))"); return
        }
        #expect(details.message.contains("already exists"))
        let reopened = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("m.sqlite")), migrations: sampleMigrations)
        #expect(try await reopened.schemaVersion() == 3)
        await reopened.close()
    }
}
