// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift
import SQLiteSwiftTesting
import Testing

/// Compiles and runs the code from the Getting Started guide.
@Suite("Getting Started guide")
struct GettingStartedTests {
    static let migrations = [
        SQLiteMigration(version: 1, name: "tasks", sql: """
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY,
                version INTEGER NOT NULL DEFAULT 1,
                state TEXT NOT NULL,
                payload BLOB NOT NULL,
                expires_at INTEGER
            );
            """),
        SQLiteMigration(version: 2, name: "expiry index") { tx throws(SQLiteError) in
            try tx.execute("CREATE INDEX tasks_by_expiry ON tasks(expires_at)")
        },
    ]

    @Test("The guide's examples work end to end")
    func guide() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let configuration = SQLiteConfiguration(path: directory.file("tasks.sqlite"))
        let database = try await SQLiteDatabase.open(configuration, migrations: Self.migrations)
        let id = "task-1"
        let canonicalJSONBytes: [UInt8] = Array(#"{"a":1}"#.utf8)
        try await database.write { tx throws(SQLiteError) in
            try tx.execute(
                "INSERT INTO tasks (id, state, payload, expires_at) VALUES (?, ?, ?, ?)",
                [.text(id), "working", .blob(canonicalJSONBytes), tx.deadline(after: .seconds(3600)).sqliteValue])
        }
        let result = try await database.write { tx throws(SQLiteError) in
            try tx.compareAndSet(
                table: "tasks", id: .text(id), expectedVersion: 1,
                assignments: [SQLiteAssignment("state", "completed")])
        }
        #expect(result == .updated(newVersion: 2))
        let rows = try await database.read { tx throws(SQLiteError) in
            try tx.query("SELECT id, state FROM tasks WHERE state = ?", ["completed"],
                         limits: SQLiteQueryLimits(maxRows: 100))
        }
        #expect(rows.count == 1)
        let readVersion: Int64 = 2
        let guarded = try await database.write { tx throws(SQLiteError) in
            try tx.compareAndSet(
                table: "tasks", id: .text(id), expectedVersion: readVersion,
                assignments: [SQLiteAssignment("state", "cancelled")],
                alsoRequire: .notIn("state", ["completed", "failed", "cancelled"]))
        }
        #expect(guarded == .guardFailed(currentVersion: 2))

        var cursor: SQLiteKeysetCursor?
        var scanned = 0
        repeat {
            let page = try await database.read { [cursor] tx throws(SQLiteError) in
                try tx.queryPage(
                    table: "tasks", columns: ["id", "state"], keyColumns: ["expires_at", "id"],
                    after: cursor, filter: .notIn("state", ["failed", "cancelled"]),
                    limit: 100)
            }
            scanned += page.rows.count
            cursor = page.nextCursor
        } while cursor != nil
        #expect(scanned == 1)

        let newID = "task-2"
        let bytes: [UInt8] = [1]
        do {
            try await database.write { tx throws(SQLiteError) in
                try tx.execute("INSERT INTO tasks (id, state, payload) VALUES (?, ?, ?)",
                               [.text(newID), "working", .blob(bytes)])
            }
        } catch SQLiteError.Code.commitOutcomeUnknown {
            let exists = try await database.read { tx throws(SQLiteError) in
                try tx.queryOne("SELECT 1 FROM tasks WHERE id = ?", [.text(newID)]) != nil
            }
            #expect(exists)
        }

        let deleted = try await database.write { tx throws(SQLiteError) in
            try tx.deleteExpired(from: "tasks", expiresAtColumn: "expires_at", limit: 500)
        }
        #expect(deleted == 0)
        await database.close()
    }

    @Test("The guide's conformance example", arguments: SQLiteConformanceKit.Check.allCases)
    func conformance(check: SQLiteConformanceKit.Check) async {
        let kit = SQLiteConformanceKit(migrations: Self.migrations)
        let result = await kit.run(check)
        #expect(result.outcome == .passed, "\(result.notes)")
    }
}
