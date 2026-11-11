// SPDX-License-Identifier: Apache-2.0

import SwiftSQLite
import SwiftSQLiteTesting
import Testing

@Suite("Bounded reads and statement cache")
struct LimitsTests {
    @Test("Default limits: 1 MiB results, 16 MiB hard cap, 10,000 rows, 32 statements")
    func defaults() {
        let limits = SQLiteLimits()
        #expect(limits.defaultMaxResultBytes == 1 << 20)
        #expect(limits.hardMaxResultBytes == 16 << 20)
        #expect(limits.defaultMaxRows == 10_000)
        #expect(limits.statementCacheCapacity == 32)
    }

    @Test("Row limits: configured default and per query; never silently truncated")
    func rowLimits() async throws {
        try await withDatabase(configure: { $0.limits.defaultMaxRows = 5 }) { database, _ in
            let series = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ?) SELECT x FROM c"
            let five = try await database.read { (tx) throws(SQLiteError) in try tx.query(series, [5]) }
            #expect(five.count == 5)
            let six = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.query(series, [6]) } }
            #expect(six == .rowLimitExceeded(limit: 5))
            let custom = try await database.read { (tx) throws(SQLiteError) in
                try tx.query(series, [50], limits: SQLiteQueryLimits(maxRows: 50))
            }
            #expect(custom.count == 50)
            let tooFew = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.query(series, [3], limits: SQLiteQueryLimits(maxRows: 2))
                }
            }
            #expect(tooFew == .rowLimitExceeded(limit: 2))
        }
    }

    @Test("Byte budgets: default, per query, and the hard cap")
    func byteLimits() async throws {
        try await withDatabase(configure: {
            $0.limits.defaultMaxResultBytes = 1000
            $0.limits.hardMaxResultBytes = 4000
        }) { database, _ in
            let small = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT zeroblob(992)") }
            #expect(small == .blob([UInt8](repeating: 0, count: 992)))
            let over = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT zeroblob(1001)") } }
            #expect(over == .resultTooLarge(limit: 1000))
            let wider = try await database.read { (tx) throws(SQLiteError) in
                try tx.query("SELECT zeroblob(3000)", limits: SQLiteQueryLimits(maxBytes: 4000))
            }
            #expect(wider.count == 1)
            let aboveCap = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.query("SELECT 1", limits: SQLiteQueryLimits(maxBytes: 4001))
                }
            }
            guard case .invalidArgument = aboveCap else { Issue.record("got \(String(describing: aboveCap))"); return }
            // The hard cap is SQLITE_LIMIT_LENGTH: SQLite refuses bigger values itself.
            let tooBig = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.query("SELECT zeroblob(5000)", limits: SQLiteQueryLimits(maxBytes: 4000))
                }
            }
            guard case .tooBig = tooBig else { Issue.record("got \(String(describing: tooBig))"); return }
            // Bound values above the hard cap are refused before reaching SQLite.
            let bigBind = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name, payload) VALUES ('b', ?)", [.blob([UInt8](repeating: 1, count: 4001))])
                }
            }
            #expect(bigBind == .resultTooLarge(limit: 4000))
            // Many rows add up to the budget.
            let rows = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.query("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200) SELECT x FROM c")
                }
            }
            #expect(rows == .resultTooLarge(limit: 1000))  // 200 integers x 8 bytes
        }
    }

    @Test("readBlob checks length(column) before loading the value")
    func boundedBlob() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (id, name, payload) VALUES (1, 'small', ?)", [.blob([1, 2, 3])])
                try tx.execute("INSERT INTO items (id, name, payload) VALUES (2, 'big', zeroblob(2000000))")
                try tx.execute("INSERT INTO items (id, name) VALUES (3, 'null')")
            }
            let small = try await database.read { (tx) throws(SQLiteError) in
                try tx.readBlob(table: "items", column: "payload", keyColumn: "id", key: 1)
            }
            #expect(small == [1, 2, 3])
            let big = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.readBlob(table: "items", column: "payload", keyColumn: "id", key: 2)
                }
            }
            #expect(big == .resultTooLarge(limit: 1 << 20))
            let allowed = try await database.read { (tx) throws(SQLiteError) in
                try tx.readBlob(table: "items", column: "payload", keyColumn: "id", key: 2, maxBytes: 2_000_000)
            }
            #expect(allowed?.count == 2_000_000)
            let missing = try await database.read { (tx) throws(SQLiteError) in
                try tx.readBlob(table: "items", column: "payload", keyColumn: "id", key: 99)
            }
            #expect(missing == nil)
            let null = try await database.read { (tx) throws(SQLiteError) in
                try tx.readBlob(table: "items", column: "payload", keyColumn: "id", key: 3)
            }
            #expect(null == nil)
            let injection = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.readBlob(table: "items; DROP TABLE items", column: "payload", keyColumn: "id", key: 1)
                }
            }
            guard case .sqlite = injection else { Issue.record("got \(String(describing: injection))"); return }
        }
    }

    @Test("The prepared-statement cache is bounded", arguments: [0, 4])
    func statementCacheBounded(capacity: Int) async throws {
        try await withDatabase(configure: { $0.limits.statementCacheCapacity = capacity }) { database, _ in
            let cached = try await database.write { (tx) throws(SQLiteError) -> Int in
                for index in 0..<20 {
                    _ = try tx.scalar("SELECT \(index)")
                    _ = try tx.scalar("SELECT \(index)")
                }
                return tx.cachedStatementCount
            }
            #expect(cached == capacity)
        }
    }

    @Test("Identifiers are quoted and validated")
    func identifiers() throws {
        #expect(try SQLiteIdentifier("plain").quoted() == "\"plain\"")
        #expect(try SQLiteIdentifier("we\"ird").quoted() == "\"we\"\"ird\"")
        #expect(throws: SQLiteError.self) { try SQLiteIdentifier("").quoted() }
        #expect(throws: SQLiteError.self) { try SQLiteIdentifier("a\u{0}b").quoted() }
    }
}
