// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModels
import Testing

@Suite("1.2: records from custom SQL")
struct CustomSQLTests {
    let articles = [
        Article(id: "a1", title: "Zeta", summary: nil, featured: true, status: .published),
        Article(id: "a2", title: "Alpha", summary: "first", featured: false, status: .draft),
        Article(id: "a3", title: "Mid", summary: nil, featured: false, status: .draft),
    ]

    private func seeded(_ body: (SQLiteDatabase) async throws -> Void) async throws {
        try await withRecordDatabase { database in
            let items = articles
            try await database.write { (tx) throws(SQLiteError) in
                for article in items { _ = try tx.insert(article) }
                try tx.executeScript("""
                    CREATE TABLE tags (article_id TEXT NOT NULL, tag TEXT NOT NULL);
                    INSERT INTO tags VALUES ('a1', 'swift'), ('a2', 'swift'), ('a3', 'sqlite');
                    """)
            }
            try await body(database)
        }
    }

    @Test("A join with a bound value and its own ordering maps to records by name")
    func joinAndOrder() async throws {
        try await seeded { database in
            let rows = try await database.read { (tx) throws(SQLiteError) in
                try tx.fetchAll(Article.self, sql: """
                    SELECT a.* FROM articles a JOIN tags t ON t.article_id = a.id
                    WHERE t.tag = ? ORDER BY a.title
                    """, ["swift"])
            }
            #expect(rows.map(\.value.title) == ["Alpha", "Zeta"])
            #expect(rows.allSatisfy { $0.version.revision == 1 && $0.version.incarnation.count == 16 })
            let direct = try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a2") }
            #expect(rows.first == direct)
        }
    }

    @Test("Column order doesn't matter, aliases work, extra columns are ignored")
    func namesNotPositions() async throws {
        try await seeded { database in
            let rows = try await database.read { (tx) throws(SQLiteError) in
                try tx.fetchAll(Article.self, sql: """
                    SELECT incarnation, revision, status, featured, summary, title, a.id AS id,
                           (SELECT count(*) FROM tags WHERE article_id = a.id) AS tag_count
                    FROM articles a WHERE a.id = ?
                    """, ["a2"])
            }
            #expect(rows.map(\.value) == [articles[1]])
            let none = try await database.read { (tx) throws(SQLiteError) in
                try tx.fetchAll(Article.self, sql: "SELECT * FROM articles WHERE id = ?", ["nope"])
            }
            #expect(none.isEmpty)
        }
    }

    @Test("Missing and ambiguous columns, and refused values, are errors with names")
    func errors() async throws {
        try await seeded { database in
            let missing = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.fetchAll(Article.self, sql: "SELECT id, title, summary, featured, status, revision FROM articles")
                }
            }
            #expect(missing?.code == .schemaMismatch)
            #expect(missing?.description.contains("incarnation") == true)

            let ambiguous = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.fetchAll(Article.self, sql: "SELECT a.*, b.id FROM articles a JOIN articles b ON b.id = a.id")
                }
            }
            #expect(ambiguous?.code == .invalidArgument)

            let refused = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.fetchAll(Article.self, sql: """
                        SELECT id, title, summary, 5 AS featured, status, revision, incarnation FROM articles
                        """)
                }
            }
            #expect(refused?.code == .invalidStoredValue && refused?.column == "featured")

            let limited = await caught {
                try await database.read { (tx) throws(SQLiteError) in
                    try tx.fetchAll(Article.self, sql: "SELECT * FROM articles", limits: SQLiteQueryLimits(maxRows: 2))
                }
            }
            #expect(limited?.code == .rowLimitExceeded)
        }
    }
}
