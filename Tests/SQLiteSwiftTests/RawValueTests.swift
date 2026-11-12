// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift
import SQLiteSwiftTesting
import Testing

@Suite("Raw, byte-exact values")
struct RawValueTests {
    private let rawSchema = [
        SQLiteMigration(version: 1, name: "raw", sql: "CREATE TABLE raw (id INTEGER PRIMARY KEY, t TEXT, b BLOB);")
    ]

    @Test("TEXT with invalid UTF-8 and embedded NUL round-trips byte for byte")
    func textRoundTrip() async throws {
        let bytes: [UInt8] = [0x61, 0x00, 0x62, 0xFF, 0xFE, 0xC3, 0x28, 0x7A]
        try await withDatabase(migrations: rawSchema) { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.executeRaw("INSERT INTO raw (id, t, b) VALUES (1, ?, ?)", [.text(bytes), .blob(bytes)])
                try tx.executeRaw("INSERT INTO raw (id, t, b) VALUES (2, ?, ?)", [.text([]), .null])
            }
            let rows = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryRaw("SELECT t, b, typeof(t), length(CAST(t AS BLOB)) FROM raw ORDER BY id")
            }
            #expect(rows[0][0] == .text(bytes))
            #expect(rows[0][1] == .blob(bytes))
            #expect(rows[0][2] == .text(Array("text".utf8)))
            #expect(rows[0][3] == .integer(Int64(bytes.count)))
            #expect(try rows[0].bytes(0) == bytes)
            #expect(rows[1][0] == .text([]))
            #expect(try rows[1].bytes(1) == nil)
            #expect(rows[0]["t"] == .text(bytes))
            // The decoded API repairs the same bytes, which is why raw rows exist.
            let decoded = try await database.read { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT t FROM raw WHERE id = 1")!.text(0)
            }
            #expect(Array(decoded.utf8) != bytes)
        }
    }

    @Test("Raw queries honor row limits and byte budgets")
    func rawLimits() async throws {
        try await withDatabase(migrations: rawSchema) { database, _ in
            try await database.write { (tx) throws(SQLiteError) in
                for id in 1...3 {
                    try tx.executeRaw("INSERT INTO raw (id, t) VALUES (?, ?)", [.integer(Int64(id)), .text([UInt8](repeating: 0x41, count: 100))])
                }
            }
            let tooMany = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.queryRaw("SELECT t FROM raw", limits: SQLiteQueryLimits(maxRows: 2))
                }
            }
            #expect(code(tooMany) == .rowLimitExceeded)
            let tooLarge = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.queryRaw("SELECT t FROM raw", limits: SQLiteQueryLimits(maxBytes: 250))
                }
            }
            #expect(code(tooLarge) == .resultTooLarge)
            #expect(tooLarge?.limit == 250)
        }
    }

    @Test("Raw values convert from SQLiteValue and report kind and size")
    func conversions() {
        #expect(SQLiteRawValue(SQLiteValue.text("é")) == .text([0xC3, 0xA9]))
        #expect(SQLiteRawValue(SQLiteValue.integer(7)) == .integer(7))
        #expect(SQLiteRawValue(SQLiteValue.null) == .null)
        #expect(SQLiteRawValue.text([1, 2, 3]).byteCount == 3)
        #expect(SQLiteRawValue.real(1).byteCount == 8)
        #expect(SQLiteRawValue.text([1]).kind == .text)
        #expect(SQLiteRawValue.text([0, 1]).description == "TEXT(2 bytes)")
        let row = SQLiteRawRow(columnNames: ["a"], values: [.real(1)])
        #expect(throws: SQLiteError.self) { try row.bytes(0) }
        #expect(throws: SQLiteError.self) { try row.integer(3) }
    }

    @Test("Raw statements are refused in read transactions when they write")
    func rawReadOnly() async throws {
        try await withDatabase(migrations: rawSchema) { database, _ in
            let error = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.executeRaw("INSERT INTO raw (id) VALUES (?)", [.integer(1)])
                }
            }
            #expect(code(error) == .readOnly)
        }
    }
}
