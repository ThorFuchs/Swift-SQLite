// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing

@Suite("Backups, integrity checks and maintenance")
struct MaintenanceTests {
    private func seed(_ database: SQLiteDatabase, rows: Int, payload: Int = 512) async throws {
        try await database.write { (tx) throws(SQLiteError) in
            for i in 0..<rows {
                try tx.execute("INSERT INTO items (name, payload) VALUES (?, ?)",
                               [.text("item \(i)"), .blob([UInt8](repeating: UInt8(i % 251), count: payload))])
            }
        }
    }

    private func open(_ path: String) async throws -> SQLiteDatabase {
        try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: sampleMigrations)
    }

    @Test("A backup copies one snapshot while writes continue, with progress")
    func backupDuringWrites() async throws {
        try await withDatabase { database, directory in
            try await seed(database, rows: 2_000)
            let target = directory.file("backup.sqlite")
            let steps = SQLiteLocked([SQLiteBackupProgress]())
            let writing = Task {
                for i in 0..<200 {
                    try await database.write { (tx) throws(SQLiteError) in
                        try tx.execute("INSERT INTO items (name) VALUES (?)", [.text("late \(i)")])
                    }
                }
            }
            let final = try await database.backup(to: target, pagesPerStep: 8) { step in
                steps.withLock { $0.append(step) }
            }
            try await writing.value
            let recorded = steps.withLock { $0 }
            #expect(recorded.count > 1)
            #expect(final.copiedPages == final.totalPages && final.totalPages > 8)
            #expect(recorded.map(\.copiedPages) == recorded.map(\.copiedPages).sorted())

            let copy = try await open(target)
            let report = try await copy.integrityCheck()
            #expect(report.isIntact)
            let count = try await copy.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            guard case .integer(let rows) = count else { Issue.record("no count"); return }
            #expect(rows >= 2_000 && rows <= 2_200)  // one consistent state between start and end
            await copy.close()
        }
    }

    @Test("A backup never overwrites, and a stopped backup leaves no file")
    func backupRefusalsAndStops() async throws {
        try await withDatabase { database, directory in
            try await seed(database, rows: 3_000)
            let existing = directory.file("exists.sqlite")
            FileManager.default.createFile(atPath: existing, contents: Data([1, 2, 3]))
            #expect(await caught { try await database.backup(to: existing) }?.code == .invalidArgument)
            #expect(FileManager.default.contents(atPath: existing) == Data([1, 2, 3]))
            #expect(await caught { try await database.backup(to: directory.file("x"), pagesPerStep: 0) }?.code == .invalidArgument)

            let stopped = directory.file("stopped.sqlite")
            let error = await caught {
                try await database.backup(to: stopped, pagesPerStep: 1,
                                          limits: SQLiteOperationLimits(timeout: .milliseconds(1))) { _ in
                    // Slow each step a little, so the deadline passes mid-copy.
                    usleep(2_000)
                }
            }
            #expect(error?.code == .deadlineExceeded)
            #expect(!FileManager.default.fileExists(atPath: stopped))
        }
    }

    @Test("Cancelling a backup stops it and removes the partial file")
    func backupCancellation() async throws {
        try await withDatabase { database, directory in
            try await seed(database, rows: 3_000)
            let target = directory.file("cancelled.sqlite")
            let started = SQLiteTestLatch()
            let task = Task {
                try await database.backup(to: target, pagesPerStep: 1) { step in
                    if step.copiedPages == 1 { started.blockingWait() }
                }
            }
            #expect(await started.waitUntilEntered())
            task.cancel()
            started.open()
            #expect(await caught { try await task.value }?.code == .interrupted)
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    @Test("VACUUM INTO writes a compact, intact copy")
    func vacuumInto() async throws {
        try await withDatabase { database, directory in
            try await seed(database, rows: 2_000)
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("DELETE FROM items WHERE id % 2 = 0") }
            let target = directory.file("compact.sqlite")
            try await database.vacuum(into: target)
            #expect(await caught { try await database.vacuum(into: target) }?.code == .invalidArgument)
            let copy = try await open(target)
            #expect(try await copy.quickCheck().isIntact)
            let (rows, free) = try await copy.read { (tx) throws(SQLiteError) in
                (try tx.scalar("SELECT count(*) FROM items"), try tx.scalar("PRAGMA freelist_count"))
            }
            #expect(rows == .integer(1_000) && free == .integer(0))
            await copy.close()
        }
    }

    @Test("Integrity checks pass on a sound file and report damage on a corrupted one")
    func integrityChecks() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("damaged.sqlite")
        let database = try await open(path)
        try await seed(database, rows: 2_000)
        try await database.write { (tx) throws(SQLiteError) in
            try tx.executeScript("CREATE INDEX items_payload ON items(payload)")
        }
        #expect(try await database.integrityCheck().isIntact)
        #expect(try await database.quickCheck().isIntact)
        #expect(await caught { try await database.integrityCheck(maxProblems: 0) }?.code == .invalidArgument)
        _ = try await database.checkpoint(.truncate)
        await database.close()

        // Overwrite part of a page in the middle of the file with garbage.
        let handle = try #require(FileHandle(forUpdatingAtPath: path))
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size / 2)
        handle.write(Data(repeating: 0xA5, count: 4096))
        try handle.close()

        let damaged = try await open(path)
        let report = try await damaged.integrityCheck(maxProblems: 5)
        #expect(!report.isIntact)
        #expect(report.problems.count >= 1 && report.problems.count <= 5)
        await damaged.close()
    }

    @Test("optimize and incremental vacuum run explicitly")
    func explicitMaintenance() async throws {
        try await withDatabase(configure: { configuration in
            configuration.fileIdentity = SQLiteFileIdentity(applicationID: 0x4D41_494E, autoVacuum: .incremental)
        }) { database, _ in
            try await seed(database, rows: 2_000)
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("DELETE FROM items") }
            let before = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("PRAGMA freelist_count") }
            try await database.incrementalVacuum(pages: 10)
            let after10 = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("PRAGMA freelist_count") }
            try await database.incrementalVacuum()
            let afterAll = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("PRAGMA freelist_count") }
            guard case .integer(let b) = before, case .integer(let a) = after10 else { Issue.record("counts"); return }
            #expect(b > 10 && a == b - 10)
            #expect(afterAll == .integer(0))
            #expect(await caught { try await database.incrementalVacuum(pages: 0) }?.code == .invalidArgument)
            try await database.optimize()
        }
    }

    @Test("An in-memory database can be backed up and vacuumed into a file")
    func inMemorySources() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(.inMemory(), migrations: sampleMigrations)
        try await seed(database, rows: 500)
        try await database.backup(to: directory.file("memory-backup.sqlite"))
        try await database.vacuum(into: directory.file("memory-vacuum.sqlite"))
        await database.close()
        for name in ["memory-backup.sqlite", "memory-vacuum.sqlite"] {
            let copy = try await open(directory.file(name))
            let rows = try await copy.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(rows == .integer(500), "\(name): \(String(describing: rows))")
            #expect(try await copy.integrityCheck().isIntact)
            await copy.close()
        }
    }

    @Test("Full-text search with FTS5 works on every platform")
    func fts5() async throws {
        try await withDatabase { database, _ in
            let hits = try await database.write { (tx) throws(SQLiteError) in
                try tx.executeScript("CREATE VIRTUAL TABLE docs USING fts5(title, body)")
                try tx.execute("INSERT INTO docs (title, body) VALUES (?, ?)", ["Swift", "Durable SQLite for Swift concurrency"])
                try tx.execute("INSERT INTO docs (title, body) VALUES (?, ?)", ["Other", "Nothing to see"])
                return try tx.query("SELECT title FROM docs WHERE docs MATCH ? ORDER BY rank", ["concurrency"])
            }
            #expect(hits.count == 1)
            #expect(try hits.first?.text(0) == "Swift")
        }
    }
}
