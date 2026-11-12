// SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing

/// A query that runs for millions of VM instructions.
private let longQuery = """
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 50000000)
    SELECT count(*) FROM c
    """

private func itemCount(_ database: SQLiteDatabase, name: String) async throws -> Int64 {
    try await database.read { (tx) throws(SQLiteError) in
        try tx.queryOne("SELECT count(*) FROM items WHERE name = ?", [.text(name)])!.integer(0)
    }
}

@Suite("Operation limits: deadlines and instruction budgets")
struct OperationLimitsTests {
    @Test("An instruction budget stops a long read with instructionLimitExceeded")
    func instructionBudgetRead() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.read(limits: SQLiteOperationLimits(maxInstructions: 100_000)) {
                    (tx) throws(SQLiteError) in try tx.scalar(longQuery)
                }
            }
            #expect(code(error) == .instructionLimitExceeded)
            #expect(error?.limit == 100_000)
            #expect(error?.isInterruption == true)
            // The next operation on the same connection is not affected.
            let small = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200000) SELECT count(*) FROM c")
            }
            #expect(small == .integer(200_000))
        }
    }

    @Test("An instruction budget stops a write and rolls it back")
    func instructionBudgetWrite() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.write(limits: SQLiteOperationLimits(maxInstructions: 50_000)) {
                    (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES ('budget')")
                    _ = try tx.scalar(longQuery)
                }
            }
            #expect(code(error) == .instructionLimitExceeded)
            let leaked = try await itemCount(database, name: "budget")
            #expect(leaked == 0)
        }
    }

    @Test("A timeout stops a long statement with deadlineExceeded")
    func deadlineStopsStatement() async throws {
        try await withDatabase { database, _ in
            let start = ContinuousClock.now
            let error = await caught {
                try await database.read(limits: SQLiteOperationLimits(timeout: .milliseconds(150))) {
                    (tx) throws(SQLiteError) in try tx.scalar(longQuery)
                }
            }
            let elapsed = ContinuousClock.now - start
            #expect(code(error) == .deadlineExceeded)
            #expect(elapsed >= .milliseconds(140) && elapsed < .seconds(2), "elapsed \(elapsed)")
        }
    }

    @Test("A deadline that passes before COMMIT rolls the write back")
    func deadlineBeforeCommit() async throws {
        try await withDatabase { database, _ in
            let error = await caught {
                try await database.write(limits: SQLiteOperationLimits(timeout: .milliseconds(50))) {
                    (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES ('late')")
                    usleep(150_000)
                }
            }
            #expect(code(error) == .deadlineExceeded)
            let leaked = try await itemCount(database, name: "late")
            #expect(leaked == 0)
        }
    }

    @Test("A deadline bounds the wait for a lock held by another database")
    func deadlineBoundsBusyWait() async throws {
        try await withDatabase { database, directory in
            var otherConfig = SQLiteConfiguration(path: directory.file("test.sqlite"))
            otherConfig.busyTimeout = .seconds(30)
            let other = try await SQLiteDatabase.open(otherConfig, migrations: sampleMigrations)
            let latch = SQLiteTestLatch()
            let holder = Task { try await database.write { (_) throws(SQLiteError) in latch.blockingWait() } }
            #expect(await latch.waitUntilEntered())
            let start = ContinuousClock.now
            let error = await caught {
                try await other.write(limits: SQLiteOperationLimits(timeout: .milliseconds(200))) {
                    (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')")
                }
            }
            let elapsed = ContinuousClock.now - start
            latch.open()
            _ = try await holder.value
            await other.close()
            #expect(code(error) == .deadlineExceeded)
            #expect(elapsed >= .milliseconds(180) && elapsed < .seconds(3), "elapsed \(elapsed)")
        }
    }

    @Test("A deadline bounds the wait for a free connection")
    func deadlineBoundsPoolWait() async throws {
        try await withDatabase(configure: { $0.readerCount = 0 }) { database, _ in
            let latch = SQLiteTestLatch()
            let holder = Task { try await database.write { (_) throws(SQLiteError) in latch.blockingWait() } }
            #expect(await latch.waitUntilEntered())
            let start = ContinuousClock.now
            let error = await caught {
                try await database.read(limits: SQLiteOperationLimits(timeout: .milliseconds(150))) {
                    (tx) throws(SQLiteError) in try tx.scalar("SELECT 1")
                }
            }
            let elapsed = ContinuousClock.now - start
            latch.open()
            _ = try await holder.value
            #expect(code(error) == .deadlineExceeded)
            #expect(elapsed >= .milliseconds(140) && elapsed < .seconds(3), "elapsed \(elapsed)")
            #expect(database.writerPool.inUse == 0)
            let after = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
            #expect(after == .integer(1))
        }
    }

    @Test("Cancellation that comes first is reported as interrupted, not as the deadline")
    func firstCauseWins() async throws {
        try await withDatabase { database, _ in
            let task = Task {
                try await database.read(limits: SQLiteOperationLimits(timeout: .seconds(3))) {
                    (tx) throws(SQLiteError) in try tx.scalar(longQuery)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            let result = await task.result
            guard case .failure(let error) = result else { Issue.record("the query finished"); return }
            #expect((error as? SQLiteError)?.code == .interrupted)
        }
    }

    @Test("Configured limits apply by default; a call's own limits replace them")
    func configuredLimits() async throws {
        try await withDatabase(configure: { $0.operationLimits = SQLiteOperationLimits(maxInstructions: 20_000) }) {
            database, _ in
            let limited = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.scalar(longQuery) }
            }
            #expect(code(limited) == .instructionLimitExceeded)
            let unlimited = try await database.read(limits: .unlimited) { (tx) throws(SQLiteError) in
                try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000) SELECT count(*) FROM c")
            }
            #expect(unlimited == .integer(100_000))
        }
    }

    @Test("Invalid limits are refused")
    func invalidLimits() async throws {
        try await withDatabase { database, _ in
            let zeroTimeout = await caught {
                try await database.read(limits: SQLiteOperationLimits(timeout: .zero)) { (_) throws(SQLiteError) in }
            }
            #expect(code(zeroTimeout) == .invalidArgument)
            let zeroBudget = await caught {
                try await database.write(limits: SQLiteOperationLimits(maxInstructions: 0)) { (_) throws(SQLiteError) in }
            }
            #expect(code(zeroBudget) == .invalidArgument)
        }
        var configuration = SQLiteConfiguration.inMemory()
        configuration.operationLimits.maxInstructions = -1
        let refused = await caught { try await SQLiteDatabase.open(configuration, migrations: []) }
        #expect(code(refused) == .invalidConfiguration)
    }

    @Test("A stop at the end of one job never affects the next job on the connection")
    func lateStopNeverLeaks() async throws {
        try await withDatabase(configure: { $0.readerCount = 0 }) { database, _ in
            for round in 0..<150 {
                let task = Task {
                    try await database.write { (tx) throws(SQLiteError) in
                        try tx.execute("INSERT INTO items (name) VALUES (?)", [.text("r\(round)")])
                    }
                }
                // Cancel at varying points: before, during and after the job.
                if round % 3 != 0 { try await Task.sleep(for: .microseconds(50 * (round % 7))) }
                task.cancel()
                _ = await task.result
                // The next job must always succeed.
                let value = try await database.read { (tx) throws(SQLiteError) in
                    try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000) SELECT count(*) FROM c")
                }
                #expect(value == .integer(5000), "round \(round)")
            }
            // A budget stop is bound to its job too.
            for _ in 0..<20 {
                _ = await caught {
                    try await database.read(limits: SQLiteOperationLimits(maxInstructions: 1000)) {
                        (tx) throws(SQLiteError) in try tx.scalar(longQuery)
                    }
                }
                let value = try await database.read { (tx) throws(SQLiteError) in
                    try tx.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000) SELECT count(*) FROM c")
                }
                #expect(value == .integer(5000))
            }
        }
    }
}
