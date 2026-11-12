// SPDX-License-Identifier: Apache-2.0

@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Requirements from the MCP-Server downstream review (ADR-0004 phase C).
@Suite("Commit outcomes, durability settings, guarded CAS and pagination")
struct DownstreamTests {
    // MARK: Commit outcomes

    @Test("A COMMIT that fails after the transaction ended reports commitOutcomeUnknown")
    func commitOutcomeUnknown() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (id, name) VALUES (1, 'maybe')")
                    tx.core.failNextCommitForTesting = true
                }
            }
            guard case .commitOutcomeUnknown(let underlying) = error else {
                Issue.record("expected commitOutcomeUnknown, got \(String(describing: error))"); return
            }
            #expect(underlying.resultCode?.primary == .constraint)  // SQLITE_CONSTRAINT_COMMITHOOK
            // Resolution: a fresh read decides. Here the hook turned COMMIT into a rollback.
            let found = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT count(*) FROM items WHERE id = 1")
            }
            #expect(found == .integer(0))
            // The database keeps working.
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (id, name) VALUES (2, 'sure')")
            }
        }
    }

    @Test("A COMMIT that fails while the transaction is still open is a plain error (not committed)")
    func commitFailsWhileOpen() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("""
                    CREATE TABLE deferred_child (
                        id INTEGER PRIMARY KEY,
                        parent INTEGER REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED)
                    """)
            }
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO deferred_child (id, parent) VALUES (1, 999)")
                }
            }
            guard case .constraint(let details) = error else {
                Issue.record("expected .constraint, got \(String(describing: error))"); return
            }
            #expect(details.code.rawValue == 787)  // SQLITE_CONSTRAINT_FOREIGNKEY, reported by COMMIT
            let rows = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT count(*) FROM deferred_child")
            }
            #expect(rows == .integer(0))
        }
    }

    @Test("Cancellation before COMMIT is .interrupted and nothing is committed")
    func cancelledBeforeCommit() async throws {
        try await withDatabase { database, _ in
            let latch = SQLiteTestLatch()
            let task = Task {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (id, name) VALUES (5, 'cancelled')")
                    latch.blockingWait()
                }
            }
            #expect(await latch.waitUntilEntered())
            task.cancel()
            latch.open()
            let result = await task.result
            guard case .failure(let error) = result else { Issue.record("write succeeded"); return }
            #expect(error as? SQLiteError == .interrupted)
            let rows = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(rows == .integer(0))
        }
    }

    // MARK: Durability settings

    @Test("fullfsync is on by default on Apple platforms and verified; opt-out works")
    func fullFSyncDefault() async throws {
        #expect(SQLiteConfiguration(path: "/x").appleFullFSync)
        let on = try await withDatabase { database, _ in try await database.effectiveSettings() }
        let off = try await withDatabase(configure: { $0.appleFullFSync = false }) { database, _ in
            try await database.effectiveSettings()
        }
        #expect(on.journalMode == "wal")
        #expect(on.synchronous == 2)
        #expect(on.foreignKeys)
        #expect(!on.trustedSchema)
        #expect(!on.sqliteVersion.isEmpty && !on.sqliteSourceID.isEmpty)
        #if canImport(Darwin)
        #expect(on.fullFSync && on.checkpointFullFSync)
        #expect(!off.fullFSync && !off.checkpointFullFSync)
        #endif
    }

    @Test("A setting that doesn't read back as expected throws settingMismatch")
    func settingMismatch() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.core.verifyPragma("foreign_keys", expected: .integer(0))
                }
            }
            #expect(error == .settingMismatch(setting: "foreign_keys", expected: "0", actual: "1"))
        }
    }

    @Test("Opening in a missing directory throws .cantOpen")
    func cantOpen() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let error = await caught {
            try await SQLiteDatabase.open(
                SQLiteConfiguration(path: directory.file("missing/dir/x.sqlite")), migrations: [])
        }
        guard case .cantOpen(let details) = error else {
            Issue.record("expected .cantOpen, got \(String(describing: error))"); return
        }
        #expect(details.code.primary == .cantOpen)
    }

    @Test("A database file that isn't writable fails at open with .readOnly")
    func readOnlyFile() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("ro.sqlite")
        let database = try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: sampleMigrations)
        await database.close()
        chmod(path, 0o444)
        defer { chmod(path, 0o644) }
        if geteuid() == 0 { return }  // root ignores file permissions (e.g. some containers)
        let error = await caught {
            try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: sampleMigrations)
        }
        guard case .readOnly = error else {
            Issue.record("expected .readOnly, got \(String(describing: error))"); return
        }
    }

    @Test("I/O and can't-open result codes map to typed errors with extended codes")
    func ioErrorMapping() {
        guard case .ioError(let fsync) = SQLiteError.make(code: 1034, message: "fsync") else {  // SQLITE_IOERR_FSYNC
            Issue.record("IOERR_FSYNC"); return
        }
        #expect(fsync.code.rawValue == 1034 && fsync.code.primary == .ioError)
        guard case .cantOpen = SQLiteError.make(code: 14, message: "x") else { Issue.record("CANTOPEN"); return }
        #expect(SQLiteError.commitOutcomeUnknown(.ioError(fsync)).resultCode?.rawValue == 1034)
    }

    // MARK: Guarded compare-and-set

    @Test("Guarded CAS distinguishes updated, guardFailed, conflict and notFound")
    func guardedCompareAndSet() async throws {
        let terminal: SQLitePredicate = .notIn("name", ["completed", "failed"])
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (id, name, version) VALUES (1, 'working', 1)")
                try tx.execute("INSERT INTO items (id, name, version) VALUES (2, 'completed', 4)")
            }
            let results = try await database.write { (tx) throws(SQLiteError) -> [SQLiteCompareAndSetResult] in
                [
                    try tx.compareAndSet(table: "items", id: 1, expectedVersion: 1,
                                         assignments: [SQLiteAssignment("payload", .blob([1]))], alsoRequire: terminal),
                    try tx.compareAndSet(table: "items", id: 2, expectedVersion: 4, alsoRequire: terminal),
                    try tx.compareAndSet(table: "items", id: 2, expectedVersion: 3, alsoRequire: terminal),
                    try tx.compareAndSet(table: "items", id: 9, expectedVersion: 1, alsoRequire: terminal),
                ]
            }
            #expect(results == [
                .updated(newVersion: 2), .guardFailed(currentVersion: 4),
                .conflict(currentVersion: 4), .notFound,
            ])
            let untouched = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT version, payload FROM items WHERE id = 2")
            }
            #expect(untouched?.values == [.integer(4), .null])
        }
    }

    @Test("Predicates bind values and validate their shape")
    func predicates() throws {
        let rendered = try SQLitePredicate.and([
            .equals("owner", "o'brien\"; DROP TABLE x; --"),
            .or([.isIn("status", ["a", "b"]), .isNull("status")]),
            .not(.greaterThan("n", 3)),
        ]).render()
        #expect(rendered.sql == #"(("owner" = ?) AND (("status" IN (?, ?)) OR ("status" IS NULL)) AND (NOT ("n" > ?)))"#)
        #expect(rendered.bindings == ["o'brien\"; DROP TABLE x; --", "a", "b", 3])
        #expect(try SQLitePredicate.isIn("s", []).render().sql == "(0)")
        #expect(try SQLitePredicate.notIn("s", []).render().sql == #"("s" IS NOT NULL)"#)
        #expect(throws: SQLiteError.self) { try SQLitePredicate.equals("s", .null).render() }
        #expect(throws: SQLiteError.self) { try SQLitePredicate.isIn("s", [.null]).render() }
        #expect(throws: SQLiteError.self) {
            try SQLitePredicate.isIn("s", Array(repeating: 1, count: SQLitePredicate.maxListCount + 1)).render()
        }
        var deep: SQLitePredicate = .isNull("x")
        for _ in 0...SQLitePredicate.maxDepth { deep = .not(deep) }
        #expect(throws: SQLiteError.self) { try deep.render() }
    }

    // MARK: Keyset pagination

    @Test("Keyset pagination walks all rows in bounded, stable pages")
    func keysetPagination() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, created INTEGER NOT NULL, status TEXT NOT NULL)")
                try tx.execute("CREATE INDEX tasks_by_created ON tasks(created, id)")
                for index in 0..<25 {
                    // Pairs of rows share a timestamp, so the id breaks ties.
                    try tx.execute("INSERT INTO tasks VALUES (?, ?, ?)",
                                   [.text(String(format: "t%02d", index)), .integer(Int64(index / 2)),
                                    .text(index % 5 == 0 ? "completed" : "working")])
                }
            }
            let notTerminal: SQLitePredicate = .notIn("status", ["completed", "failed"])
            var seen: [String] = []
            var cursor: SQLiteKeysetCursor?
            var pages = 0
            repeat {
                let page = try await database.read { [cursor] (tx) throws(SQLiteError) in
                    try tx.queryPage(table: "tasks", columns: ["id"], keyColumns: ["created", "id"],
                                     after: cursor, filter: notTerminal, limit: 7)
                }
                for row in page.rows { seen.append(try row.text(0)) }
                #expect(page.rows.first?.columnNames == ["id", "created"])
                cursor = page.nextCursor
                pages += 1
                if pages == 1 {
                    // A row inserted behind the cursor doesn't disturb later pages.
                    try await database.write { (tx) throws(SQLiteError) in
                        try tx.execute("INSERT INTO tasks VALUES ('a-early', -1, 'working')")
                    }
                }
            } while cursor != nil && pages < 10
            let expected = (0..<25).filter { $0 % 5 != 0 }.map { String(format: "t%02d", $0) }
            #expect(seen == expected)
            #expect(pages == 3)

            let descending = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryPage(table: "tasks", columns: ["id"], keyColumns: ["created", "id"],
                                 descending: true, limit: 2)
            }
            #expect(try descending.rows.map { (row) throws(SQLiteError) in try row.text(0) } == ["t24", "t23"])
            #expect(descending.nextCursor == SQLiteKeysetCursor(values: [11, "t23"]))

            let badCursor = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.queryPage(table: "tasks", columns: ["id"], keyColumns: ["created", "id"],
                                     after: SQLiteKeysetCursor(values: [1]), limit: 5)
                }
            }
            guard case .invalidArgument = badCursor else { Issue.record("got \(String(describing: badCursor))"); return }
            let badLimit = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.queryPage(table: "tasks", columns: ["id"], keyColumns: ["id"], limit: 0)
                }
            }
            guard case .invalidArgument = badLimit else { Issue.record("got \(String(describing: badLimit))"); return }
        }
    }

    // MARK: Shutdown

    @Test("close() lets running work finish, fails waiting work with .closed, and joins all threads")
    func closeSemantics() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration.singleConnection(path: directory.file("close.sqlite")), migrations: sampleMigrations)
        let latch = SQLiteTestLatch()
        let running = Task {
            try await database.write { (tx) throws(SQLiteError) in
                latch.blockingWait()
                return try tx.execute("INSERT INTO items (name) VALUES ('ran')")
            }
        }
        #expect(await latch.waitUntilEntered())
        let waiting = Task {
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('waited')") }
        }
        try await Task.sleep(for: .milliseconds(50))
        let closing = Task { await database.close() }
        try await Task.sleep(for: .milliseconds(50))
        latch.open()
        await closing.value
        // After close returns, nothing runs any more and every thread is joined.
        #expect(database.allWorkersExited)
        #expect(try await running.value.changedRows == 1)
        let waitedResult = await waiting.result
        guard case .failure(let error) = waitedResult else { Issue.record("waiting write ran after close"); return }
        #expect(error as? SQLiteError == .closed)
        let reopened = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("close.sqlite")), migrations: sampleMigrations)
        let names = try await reopened.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT group_concat(name) FROM items") }
        await reopened.close()
        #expect(names == .text("ran"))
    }
}
