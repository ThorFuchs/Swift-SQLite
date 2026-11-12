// SPDX-License-Identifier: Apache-2.0

@testable import SQLiteSwift
import SQLiteSwiftTesting
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Database basics")
struct DatabaseTests {
    @Test("Values round-trip through bindings and results")
    func roundTrip() async throws {
        try await withDatabase { database, _ in
            let bytes: [UInt8] = [0, 1, 2, 255]
            let changes = try await database.write { (tx) throws(SQLiteError) in
                try tx.execute(
                    "INSERT INTO items (name, payload, expires_at) VALUES (?, ?, ?)",
                    ["ä 🧪 \u{0}nul", .blob(bytes), nil])
            }
            #expect(changes.changedRows == 1)
            #expect(changes.lastInsertRowID == 1)
            let row = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT name, payload, expires_at, version, 1.5, x'' FROM items")
            }
            let found = try #require(row)
            #expect(try found.text(0) == "ä 🧪 \u{0}nul")
            #expect(try found.blob(1) == bytes)
            #expect(try found.optionalInteger(2) == nil)
            #expect(try found.integer(3) == 1)
            #expect(try found.real(4) == 1.5)
            #expect(try found.blob(5) == [])
            #expect(found["name"] == .text("ä 🧪 \u{0}nul"))
            #expect(found.columnNames.count == 6)
            #expect(throws: SQLiteError.typeMismatch(column: 0, expected: .integer, actual: .text)) {
                try found.integer(0)
            }
            #expect(throws: SQLiteError.self) { try found.integer(99) }
        }
    }

    @Test("Pragmas: WAL, synchronous=FULL by default, foreign keys, busy handler")
    func defaultPragmas() async throws {
        try await withDatabase { database, _ in
            let (journal, synchronous, foreignKeys) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.scalar("PRAGMA journal_mode"), try tx.scalar("PRAGMA synchronous"),
                 try tx.scalar("PRAGMA foreign_keys"))
            }
            #expect(journal == .text("wal"))
            #expect(synchronous == .integer(2))  // FULL
            #expect(foreignKeys == .integer(1))
            let readerSynchronous = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("PRAGMA synchronous")
            }
            #expect(readerSynchronous == .integer(2))
        }
    }

    @Test("synchronous=NORMAL is an explicit opt-in")
    func normalOptIn() async throws {
        #expect(SQLiteConfiguration(path: "/x").synchronous == .full)
        try await withDatabase(configure: { $0.synchronous = .normal }) { database, _ in
            let value = try await database.write { (tx) throws(SQLiteError) in try tx.scalar("PRAGMA synchronous") }
            #expect(value == .integer(1))  // NORMAL
        }
    }

    @Test("A write is visible to another database instance as soon as it returns")
    func writeReturnsAfterCommit() async throws {
        try await withDatabase { database, directory in
            var otherConfig = SQLiteConfiguration(path: directory.file("test.sqlite"))
            otherConfig.readerCount = 1
            let other = try await SQLiteDatabase.open(otherConfig, migrations: sampleMigrations)
            for index in 0..<20 {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES (?)", [.text("n\(index)")])
                }
                let seen = try await other.read { (tx) throws(SQLiteError) in
                    try tx.scalar("SELECT count(*) FROM items")
                }
                #expect(seen == .integer(Int64(index + 1)))
            }
            await other.close()
        }
    }

    @Test("Typed constraint errors keep the extended result code")
    func constraint() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            let unique = await caught {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            }
            guard let uniqueDetails = details(unique, .constraint) else {
                Issue.record("expected .constraint, got \(String(describing: unique))"); return
            }
            #expect(uniqueDetails.code.rawValue == 2067)  // SQLITE_CONSTRAINT_UNIQUE
            #expect(uniqueDetails.code.primary == .constraint)
            let foreignKey = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO tags (item_id, tag) VALUES (999, 'x')")
                }
            }
            guard let fk = details(foreignKey, .constraint) else {
                Issue.record("expected FK .constraint, got \(String(describing: foreignKey))"); return
            }
            #expect(fk.code.rawValue == 787)  // SQLITE_CONSTRAINT_FOREIGNKEY
        }
    }

    @Test("A throwing write rolls back; writeOrRollback can roll back with a value")
    func rollback() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES ('gone')")
                    throw SQLiteError.invalidArgument("domain abort")
                }
            }
            #expect(error == .invalidArgument("domain abort"))
            let value = try await database.writeOrRollback { (tx) throws(SQLiteError) -> SQLiteTransactionOutcome<String> in
                try tx.execute("INSERT INTO items (name) VALUES ('also gone')")
                return .rollback("kept value")
            }
            #expect(value == "kept value")
            let count = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(count == .integer(0))
        }
    }

    @Test("Read transactions refuse writes; transaction control is refused")
    func guards() async throws {
        try await withDatabase(configure: { $0.readerCount = 0 }) { database, _ in
            let readWrite = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            }
            guard code(readWrite) == .readOnly else { Issue.record("got \(String(describing: readWrite))"); return }
            let scriptWrite = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.executeScript("DELETE FROM items;") }
            }
            guard code(scriptWrite) == .readOnly else { Issue.record("got \(String(describing: scriptWrite))"); return }
            for statement in ["COMMIT", "BEGIN", "ROLLBACK"] {
                let error = await caught {
                    try await database.write { (tx) throws(SQLiteError) in try tx.execute(statement) }
                }
                #expect(error != nil, "\(statement) was accepted inside a transaction")
            }
            // Savepoints stay available.
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("SAVEPOINT s1")
                try tx.execute("INSERT INTO items (name) VALUES ('sp')")
                try tx.execute("ROLLBACK TO s1")
                try tx.execute("RELEASE s1")
            }
            let multiple = await caught {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("SELECT 1; SELECT 2") }
            }
            guard code(multiple) == .invalidArgument else { Issue.record("got \(String(describing: multiple))"); return }
            let wrongCount = await caught {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("SELECT ?", []) }
            }
            guard code(wrongCount) == .invalidArgument else { Issue.record("got \(String(describing: wrongCount))"); return }
        }
    }

    @Test("A transaction used after its closure throws misuse")
    func escapedTransaction() async throws {
        final class Box: @unchecked Sendable { var transaction: SQLiteTransaction? }
        let box = Box()
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in box.transaction = tx }
            let error = await caught {
                try await database.write { (_) throws(SQLiteError) in
                    try box.transaction!.execute("SELECT 1")
                }
            }
            guard code(error) == .misuse else { Issue.record("got \(String(describing: error))"); return }
        }
    }

    @Test("Closures run on dedicated named threads, not the cooperative pool")
    func dedicatedThreads() async throws {
        try await withDatabase { database, _ in
            let writerName = try await database.write { (_) throws(SQLiteError) in currentThreadName() }
            let readerName = try await database.read { (_) throws(SQLiteError) in currentThreadName() }
            #expect(writerName == "sqliteswift.w")
            #expect(readerName.hasPrefix("sqliteswift.r"))
        }
    }

    @Test("close() joins every worker thread; later calls throw .closed; close is idempotent")
    func closeJoins() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("c.sqlite")), migrations: sampleMigrations)
        #expect(!database.allWorkersExited)
        async let first: Void = database.close()
        async let second: Void = database.close()
        _ = await (first, second)
        await database.close()
        #expect(database.allWorkersExited)
        let error = await caught {
            try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
        }
        #expect(error == .closed)
        // The last connection checkpointed the WAL on close (Apple keeps an empty file).
        #expect((SQLiteCrashImage.fileSize(directory.file("c.sqlite-wal")) ?? 0) == 0)
    }

    @Test("close() waits for running operations to finish")
    func closeWaits() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("w.sqlite")), migrations: sampleMigrations)
        let latch = SQLiteTestLatch()
        let running = Task {
            try await database.write { (tx) throws(SQLiteError) in
                latch.blockingWait()
                try tx.execute("INSERT INTO items (name) VALUES ('finished')")
            }
        }
        #expect(await latch.waitUntilEntered())
        let closing = Task { await database.close() }
        try await Task.sleep(for: .milliseconds(50))
        latch.open()
        try await running.value
        await closing.value
        let reopened = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("w.sqlite")), migrations: sampleMigrations)
        let count = try await reopened.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
        await reopened.close()
        #expect(count == .integer(1))
    }

    @Test("A file that isn't a database is reported as corrupt")
    func notADatabase() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("garbage.sqlite")
        Array(repeating: UInt8(0x5A), count: 8192).withUnsafeBufferPointer { buffer in
            let file = fopen(path, "wb")!
            fwrite(buffer.baseAddress, 1, buffer.count, file)
            fclose(file)
        }
        let error = await caught { try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: []) }
        guard let details = details(error, .corrupt) else { Issue.record("got \(String(describing: error))"); return }
        #expect(details.code.primary == .notADatabase)
    }

    @Test("Invalid configurations are refused before opening")
    func configurationValidation() async throws {
        func refused(_ change: (inout SQLiteConfiguration) -> Void) async -> Bool {
            var configuration = SQLiteConfiguration(path: "/nonexistent-dir/never.sqlite")
            change(&configuration)
            guard await code(caught({ try await SQLiteDatabase.open(configuration, migrations: []) })) == .invalidConfiguration
            else { return false }
            return true
        }
        #expect(await refused { $0.readerCount = -1 })
        #expect(await refused { $0.readerCount = 65 })
        #expect(await refused { $0.busyTimeout = .seconds(-1) })
        #expect(await refused { $0.limits.defaultMaxResultBytes = 32 << 20 })
        #expect(await refused { $0.limits.hardMaxResultBytes = 0 })
        #expect(await refused { $0.limits.defaultMaxRows = 0 })
        #expect(await refused { $0.limits.statementCacheCapacity = 5000 })
        #expect(await refused { $0.storage = .file(path: "") })
        #expect(await refused { $0.storage = .file(path: ":memory:") })
        #expect(await refused { $0.storage = .inMemory })  // readerCount 4
        let gap = [SQLiteMigration(version: 1, name: "a", sql: ""), SQLiteMigration(version: 3, name: "c", sql: "")]
        let error = await caught { try await SQLiteDatabase.open(.inMemory(), migrations: gap) }
        guard code(error) == .invalidConfiguration else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test("File-protection classes map to Apple's SQLITE_OPEN_FILEPROTECTION_* values")
    func fileProtectionFlags() {
        #expect(SQLiteFileProtection.complete.openFlag == 0x0010_0000)
        #expect(SQLiteFileProtection.completeUnlessOpen.openFlag == 0x0020_0000)
        #expect(SQLiteFileProtection.completeUntilFirstUserAuthentication.openFlag == 0x0030_0000)
        #expect(SQLiteFileProtection.none.openFlag == 0x0040_0000)
        var configuration = SQLiteConfiguration(path: "/x")
        configuration.fileProtection = .complete
        let flags = SQLiteConnectionCore.openFlags(role: .writer, configuration: configuration)
        #if os(iOS)
        #expect(flags & 0x0070_0000 == 0x0010_0000)
        #else
        #expect(flags & 0x0070_0000 == 0)  // ignored outside iOS
        #endif
        let reader = SQLiteConnectionCore.openFlags(role: .reader(0), configuration: SQLiteConfiguration(path: "/x"))
        #expect(reader & 0x0000_0001 == 0x0000_0001)  // SQLITE_OPEN_READONLY
    }

    @Test("Result codes map to typed errors")
    func errorMapping() {
        func kind(_ code: Int32) -> SQLiteError { SQLiteError.make(code: code, message: "m") }
        guard code(kind(5)) == .busy, code(kind(6)) == .busy, code(kind(261)) == .busy else { Issue.record("busy"); return }
        guard code(kind(2067)) == .constraint, code(kind(11)) == .corrupt, code(kind(26)) == .corrupt else {
            Issue.record("constraint/corrupt"); return
        }
        guard code(kind(13)) == .full, code(kind(8)) == .readOnly, code(kind(18)) == .tooBig else {
            Issue.record("full/readOnly/tooBig"); return
        }
        #expect(kind(9) == .interrupted)
        guard let io = details(kind(266), .ioError) else { Issue.record("ioerr"); return }  // SQLITE_IOERR_READ
        #expect(io.code.primary == .ioError)
        guard let other = details(kind(1), .sqlite) else { Issue.record("generic"); return }  // SQLITE_ERROR
        #expect(other.code.rawValue == 1)
        #expect(SQLiteError.sqlite(code: .full, message: "x").resultCode == .full)
        #expect(SQLiteError.migrationFailed(version: 1, name: "a", underlying: .interrupted).resultCode == .interrupt)
    }
}
