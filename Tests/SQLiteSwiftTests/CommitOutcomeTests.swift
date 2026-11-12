// SPDX-License-Identifier: Apache-2.0

@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing

@Suite("Commit outcomes and resolution")
struct CommitOutcomeTests {
    private func hasItem(_ name: String) -> @Sendable (SQLiteTransaction) throws(SQLiteError) -> Bool {
        { (tx) throws(SQLiteError) in
            try tx.queryOne("SELECT 1 FROM items WHERE name = ?", [.text(name)]) != nil
        }
    }

    @Test("writeReportingOutcome reports committed, notCommitted and unknown")
    func threeOutcomes() async throws {
        try await withDatabase { database, _ in
            let committed = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('a')").lastInsertRowID
            }
            #expect(committed.value == 1)
            #expect(committed.error == nil)

            let duplicate = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('a')")
            }
            guard case .notCommitted(let error) = duplicate else { Issue.record("got \(duplicate)"); return }
            #expect(error.code == .constraint)

            let unknown = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('b')")
                tx.core.failNextCommitForTesting = true
            }
            guard case .unknown(let unknownError) = unknown else { Issue.record("got \(unknown)"); return }
            #expect(unknownError.code == .commitOutcomeUnknown)
            #expect(unknownError.underlying?.code == .constraint)  // SQLITE_CONSTRAINT_COMMITHOOK
        }
    }

    @Test("resolveCommit sees exactly what is durable, on a fresh connection", arguments: [4, 0])
    func resolve(readerCount: Int) async throws {
        try await withDatabase(configure: { $0.readerCount = readerCount }) { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('durable')")
            }
            _ = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('lost')")
                tx.core.failNextCommitForTesting = true
            }
            #expect(try await database.resolveCommit(hasItem("durable")))
            #expect(try await !database.resolveCommit(hasItem("lost")))
        }
    }

    @Test("resolveCommit works for in-memory databases and honors limits")
    func resolveInMemory() async throws {
        let database = try await SQLiteDatabase.open(.inMemory(), migrations: sampleMigrations)
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO items (name) VALUES ('m')")
        }
        #expect(try await database.resolveCommit(hasItem("m")))
        let stopped = await caught {
            try await database.resolveCommit(limits: SQLiteOperationLimits(maxInstructions: 1000)) {
                (tx) throws(SQLiteError) in
                _ = try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10000000) SELECT count(*) FROM c")
                return true
            }
        }
        #expect(code(stopped) == .instructionLimitExceeded)
        await database.close()
    }

    @Test("resolveCommit on a file database honors limits and refuses writes")
    func resolveProbeIsBoundedAndReadOnly() async throws {
        try await withDatabase { database, _ in
            let stopped = await caught {
                try await database.resolveCommit(limits: SQLiteOperationLimits(maxInstructions: 1000)) {
                    (tx) throws(SQLiteError) in
                    _ = try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10000000) SELECT count(*) FROM c")
                    return true
                }
            }
            #expect(code(stopped) == .instructionLimitExceeded)
            let write = await caught {
                try await database.resolveCommit { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES ('no')")
                    return true
                }
            }
            #expect(code(write) == .readOnly)
        }
    }

    @Test("resolveCommit after close throws closed")
    func resolveAfterClose() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("c.sqlite")), migrations: sampleMigrations)
        await database.close()
        let error = await caught { try await database.resolveCommit { (_) throws(SQLiteError) in true } }
        #expect(code(error) == .closed)
    }

    @Test("Errors can be caught by code")
    func catchByCode() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            var caughtConstraint = false
            do {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            } catch SQLiteError.Code.constraint {
                caughtConstraint = true
            }
            #expect(caughtConstraint)
            let error = SQLiteError.schemaTooNew(databaseVersion: 5, supportedVersion: 3)
            switch error.code {
            case .schemaTooNew: #expect(error.databaseVersion == 5 && error.supportedVersion == 3)
            default: Issue.record("wrong code \(error.code)")
            }
            #expect(error.description == "database schema version 5 is newer than supported version 3")
            #expect(SQLiteError.Code.busy.name == "busy")
            #expect(SQLiteError.typeMismatch(column: 1, expected: .blob, actual: .text).typeMismatch?.actual == .text)
            #expect(SQLiteError.settingMismatch(setting: "a", expected: "1", actual: "0").setting?.name == "a")
            #expect(SQLiteError.invalidArgument("why").reason == "why")
        }
    }
}
