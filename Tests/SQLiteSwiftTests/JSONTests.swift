// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift
import SQLiteSwiftTesting
import Testing

/// SQLite's built-in JSON functions, on every platform: Apple's system SQLite and the
/// amalgamation compiled on Linux. Values are always bound, never pasted into SQL.
@Suite("JSON in SQL")
struct JSONTests {
    private let migrations = [
        SQLiteMigration(version: 1, name: "docs", sql: """
            CREATE TABLE docs (
                id INTEGER PRIMARY KEY,
                body BLOB NOT NULL CHECK (json_valid(body, 8))   -- 8: well-formed JSONB
            );
            CREATE INDEX docs_status ON docs (body ->> '$.status');
            """)
    ]

    private func withDocs(_ body: (SQLiteDatabase) async throws -> Void) async throws {
        let database = try await SQLiteDatabase.open(.inMemory(), migrations: migrations)
        try await database.write { (tx) throws(SQLiteError) in
            for json in [
                #"{"status":"open","tags":["swift","sqlite"],"n":9007199254740993,"owner":{"name":"Ada"}}"#,
                #"{"status":"done","tags":["swift"],"n":2}"#,
                #"{"status":"open","tags":[],"n":3}"#,
            ] {
                try tx.execute("INSERT INTO docs (body) VALUES (jsonb(?))", [.text(json)])
            }
        }
        try await body(database)
        await database.close()
    }

    @Test("Store as JSONB, read back as JSON text, unchanged")
    func roundTrip() async throws {
        try await withDocs { database in
            let text = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT json(body) FROM docs WHERE id = 2")
            }
            #expect(text == .text(#"{"status":"done","tags":["swift"],"n":2}"#))
        }
    }

    @Test("Filter by a path, nested paths included")
    func filterByPath() async throws {
        try await withDocs { database in
            let (open, nested) = try await database.read { (tx) throws(SQLiteError) in
                (try tx.query("SELECT id FROM docs WHERE body ->> '$.status' = ? ORDER BY id", ["open"]),
                 try tx.query("SELECT id FROM docs WHERE body ->> '$.owner.name' = ?", ["Ada"]))
            }
            #expect(try open.map { try $0.integer(0) } == [1, 3])
            #expect(try nested.map { try $0.integer(0) } == [1])
        }
    }

    @Test("Search inside arrays with json_each")
    func searchArrays() async throws {
        try await withDocs { database in
            let rows = try await database.read { (tx) throws(SQLiteError) in
                try tx.query("""
                    SELECT DISTINCT d.id FROM docs d, json_each(d.body, '$.tags') t
                    WHERE t.value = ? ORDER BY d.id
                    """, ["swift"])
            }
            #expect(try rows.map { try $0.integer(0) } == [1, 2])
        }
    }

    @Test("An index on a JSON path is used by the query planner")
    func indexOnPath() async throws {
        try await withDocs { database in
            let plan = try await database.read { (tx) throws(SQLiteError) -> [String] in
                var lines: [String] = []
                for row in try tx.query("EXPLAIN QUERY PLAN SELECT id FROM docs WHERE body ->> '$.status' = 'open'") {
                    lines.append(try row.text(3))
                }
                return lines
            }
            #expect(plan.contains { $0.contains("USING") && $0.contains("INDEX docs_status") }, "\(plan)")
        }
    }

    @Test("Integers above 2^53 stay exact")
    func exactIntegers() async throws {
        try await withDocs { database in
            let n = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT body ->> '$.n' FROM docs WHERE id = 1")
            }
            #expect(n == .integer(9_007_199_254_740_993))
        }
    }

    @Test("Malformed JSON is refused; the check constraint keeps the column valid")
    func malformed() async throws {
        try await withDocs { database in
            let parse = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO docs (body) VALUES (jsonb(?))", ["{"])
                }
            }
            #expect(parse != nil)
            let constraint = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO docs (body) VALUES (?)", [.blob([0xFF, 0x00])])
                }
            }
            #expect(constraint?.code == .constraint)
        }
    }

    @Test("Update one field in place with jsonb_set")
    func updateInPlace() async throws {
        try await withDocs { database in
            let status = try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("UPDATE docs SET body = jsonb_set(body, '$.status', ?) WHERE id = ?", ["done", 3])
                return try tx.scalar("SELECT body ->> '$.status' FROM docs WHERE id = 3")
            }
            #expect(status == .text("done"))
        }
    }

    // MARK: Typed JSON predicates

    private func ids(_ database: SQLiteDatabase, _ predicate: SQLitePredicate) async throws -> [Int64] {
        let (sql, bindings) = try predicate.render()
        return try await database.read { (tx) throws(SQLiteError) -> [Int64] in
            var ids: [Int64] = []
            for row in try tx.query("SELECT id FROM docs WHERE \(sql) ORDER BY id", bindings) { ids.append(try row.integer(0)) }
            return ids
        }
    }

    @Test("A JSON predicate renders a checked path literal and binds the value")
    func rendering() throws {
        let (sql, bindings) = try SQLitePredicate.equals("body", path: "$.owner.name", "Ada").render()
        #expect(sql == #"("body" ->> '$.owner.name' = ?)"#)
        #expect(bindings == [.text("Ada")])
    }

    @Test("Typed JSON predicates: comparisons, lists, null, arrays, combinations")
    func typedPredicates() async throws {
        try await withDocs { database in
            let r1 = try await ids(database, .equals("body", path: "$.status", "open"))
            #expect(r1 == [1, 3])
            let r2 = try await ids(database, .notEquals("body", path: "$.status", "open"))
            #expect(r2 == [2])
            let r3 = try await ids(database, .greaterThan("body", path: "$.n", 2))
            #expect(r3 == [1, 3])
            let r4 = try await ids(database, .lessThanOrEqual("body", path: "$.n", 2))
            #expect(r4 == [2])
            let r5 = try await ids(database, .isIn("body", path: "$.status", ["done", "review"]))
            #expect(r5 == [2])
            let r6 = try await ids(database, .notIn("body", path: "$.status", ["done"]))
            #expect(r6 == [1, 3])
            let r7 = try await ids(database, .isNull("body", path: "$.owner"))
            #expect(r7 == [2, 3])
            let r8 = try await ids(database, .isNotNull("body", path: "$.owner.name"))
            #expect(r8 == [1])
            let r9 = try await ids(database, .contains("body", path: "$.tags", "swift"))
            #expect(r9 == [1, 2])
            let r10 = try await ids(database, .equals("body", path: "$.tags[1]", "sqlite"))
            #expect(r10 == [1])
            let r11 = try await ids(database, .and([.equals("body", path: "$.status", "open"),
                                                  .contains("body", path: "$.tags", "sqlite")]))
            #expect(r11 == [1])
        }
    }

    @Test("The index on the same path is used, also with the quoted column name")
    func typedPredicateUsesIndex() async throws {
        try await withDocs { database in
            let (sql, bindings) = try SQLitePredicate.equals("body", path: "$.status", "open").render()
            let plan = try await database.read { (tx) throws(SQLiteError) -> [String] in
                var lines: [String] = []
                for row in try tx.query("EXPLAIN QUERY PLAN SELECT id FROM docs WHERE \(sql)", bindings) {
                    lines.append(try row.text(3))
                }
                return lines
            }
            #expect(plan.contains { $0.contains("INDEX docs_status") }, "\(plan)")
        }
    }

    @Test("Typed JSON predicates work where predicates are accepted, for example keyset paging")
    func inQueryPage() async throws {
        try await withDocs { database in
            let page = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryPage(table: "docs", columns: ["id"], keyColumns: ["id"],
                                 filter: .contains("body", path: "$.tags", "swift"), limit: 10)
            }
            #expect(try page.rows.map { try $0.integer(0) } == [1, 2])
        }
    }

    @Test("Unsafe or unsupported paths and NULL comparisons are refused", arguments: [
        "status", "$.a'b", "$..a", "$.1a", "$[x]", "$.a b", "$.a]", "$[1", "", "$.a\u{0}",
    ])
    func refusedPaths(path: String) {
        let error = rejection { () throws(SQLiteError) in _ = try SQLitePredicate.equals("body", path: SQLiteJSONPath(path), "x").render() }
        #expect(error?.code == .invalidArgument, "\(path)")
    }

    @Test("NULL values are refused; use isNull")
    func nullRefused() {
        let error = rejection { () throws(SQLiteError) in _ = try SQLitePredicate.equals("body", path: "$.status", .null).render() }
        #expect(error?.code == .invalidArgument)
    }

    private func rejection(_ body: () throws(SQLiteError) -> Void) -> SQLiteError? {
        do throws(SQLiteError) {
            try body()
            return nil
        } catch {
            return error
        }
    }
}
