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
