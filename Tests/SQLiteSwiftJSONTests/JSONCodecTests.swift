// SPDX-License-Identifier: Apache-2.0

#if SwiftJSON
import Foundation
import JSON
import SQLiteSwift
import SQLiteSwiftJSON
import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

struct Event: SQLiteRecord {
    var id: String
    var payload: JSON

    static let idColumn = SQLiteColumn("id", \Event.id, .text)
    static let payloadColumn = SQLiteColumn("payload", \Event.payload, .jsonText)
    static let descriptor = SQLiteRecordDescriptor(table: "events", key: idColumn, columns: payloadColumn) {
        row throws(SQLiteError) in
        Event(id: try row.value(idColumn), payload: try row.value(payloadColumn))
    }
}

struct Settings: Codable, Sendable, Equatable {
    var theme: String
    var fontSize: Int
    var tags: [String]
}

struct Profile: SQLiteRecord {
    var id: Int64
    var settings: Settings

    static let idColumn = SQLiteColumn("id", \Profile.id, .integer)
    static let settingsColumn = SQLiteColumn("settings", \Profile.settings, .json(Settings.self))
    static let descriptor = SQLiteRecordDescriptor(table: "profiles", key: idColumn, columns: settingsColumn) {
        row throws(SQLiteError) in
        Profile(id: try row.value(idColumn), settings: try row.value(settingsColumn))
    }
}

let jsonMigrations = [
    SQLiteMigration(version: 1, name: "events", sql: """
        CREATE TABLE events (id TEXT PRIMARY KEY, payload, revision INTEGER NOT NULL, incarnation BLOB NOT NULL);
        CREATE INDEX events_status ON events (payload ->> '$.status');
        CREATE TABLE profiles (id INTEGER PRIMARY KEY, settings, revision INTEGER NOT NULL, incarnation BLOB NOT NULL);
        """)
]

@Suite("Swift-JSON codecs (trait SwiftJSON)")
struct JSONCodecTests {
    private func withDatabase(_ body: (SQLiteDatabase) async throws -> Void) async throws {
        let database = try await SQLiteDatabase.open(.inMemory(), migrations: jsonMigrations)
        try await body(database)
        await database.close()
    }

    @Test("A JSON value round-trips exactly, big numbers and key order included")
    func roundTrip() async throws {
        try await withDatabase { database in
            let payload = try JSON.parse(#"{"status":"open","n":9007199254740993,"price":0.10,"z":1,"a":2}"#)
            let event = Event(id: "e1", payload: payload)
            try await database.write { (tx) throws(SQLiteError) in _ = try tx.insert(event) }
            let (stored, text) = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetch(Event.self, id: "e1"), try tx.scalar("SELECT payload FROM events"))
            }
            #expect(stored?.value == event)
            #expect(text == .text(#"{"status":"open","n":9007199254740993,"price":0.10,"z":1,"a":2}"#))
        }
    }

    @Test("SQLite's JSON functions and a path index work on the stored column")
    func sqlFunctions() async throws {
        try await withDatabase { database in
            try await database.write { (tx) throws(SQLiteError) in
                for (id, status) in [("e1", "open"), ("e2", "done"), ("e3", "open")] {
                    _ = try tx.insert(Event(id: id, payload: try! JSON.parse(#"{"status":"\#(status)"}"#)))
                }
            }
            let (open, plan) = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetchAll(Event.self, sql: "SELECT * FROM events WHERE payload ->> '$.status' = ? ORDER BY id", ["open"]),
                 try tx.query("EXPLAIN QUERY PLAN SELECT id FROM events WHERE payload ->> '$.status' = 'open'"))
            }
            #expect(open.map(\.value.id) == ["e1", "e3"])
            #expect(try plan.contains { try $0.text(3).contains("events_status") })
        }
    }

    @Test("Reading is strict: invalid JSON, JSONB BLOBs and NULL are refused, naming the column")
    func strictDecoding() async throws {
        try await withDatabase { database in
            // The path index makes SQLite refuse malformed JSON on write; drop it to store
            // bad values and test that reading refuses them too.
            try await database.write { (tx) throws(SQLiteError) in try tx.executeScript("DROP INDEX events_status") }
            for (sql, expected) in [
                ("INSERT INTO events VALUES ('bad', '{\"a\":', 1, randomblob(16))", "not valid JSON"),
                ("INSERT INTO events VALUES ('bad', jsonb('{\"a\":1}'), 1, randomblob(16))", "BLOB"),
                ("INSERT INTO events VALUES ('bad', NULL, 1, randomblob(16))", "NULL"),
            ] {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("DELETE FROM events")
                    try tx.execute(sql)
                }
                let error = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Event.self, id: "bad") } }
                #expect(error?.code == .invalidStoredValue && error?.column == "payload", "\(sql)")
                #expect(error?.reason?.contains(expected) == true, "\(String(describing: error?.reason))")
            }
        }
    }

    @Test("With an index on a path, SQLite itself refuses malformed JSON on write")
    func indexRefusesMalformed() async throws {
        try await withDatabase { database in
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO events VALUES ('bad', '{\"a\":', 1, randomblob(16))")
                }
            }
            #expect(error != nil)
        }
    }

    @Test("A Codable value is stored as JSON text and read back")
    func codable() async throws {
        try await withDatabase { database in
            let profile = Profile(id: 1, settings: Settings(theme: "dark", fontSize: 14, tags: ["a", "b"]))
            try await database.write { (tx) throws(SQLiteError) in _ = try tx.insert(profile) }
            let (stored, theme) = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetch(Profile.self, id: 1), try tx.scalar("SELECT settings ->> '$.theme' FROM profiles"))
            }
            #expect(stored?.value == profile)
            #expect(theme == .text("dark"))

            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute(#"UPDATE profiles SET settings = '{"theme":"x"}'"#)
            }
            let error = await caught { try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Profile.self, id: 1) } }
            #expect(error?.code == .invalidStoredValue && error?.column == "settings")
        }
    }
}

func caught<T>(_ operation: () async throws -> T) async -> SQLiteError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error as? SQLiteError
    }
}
#endif
