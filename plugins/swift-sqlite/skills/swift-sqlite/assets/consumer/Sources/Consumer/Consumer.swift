// SPDX-License-Identifier: Apache-2.0
// Canonical executable recipes for the swift-sqlite skill. Public API only.
// Every `// RECIPE id` marker is listed in references/recipes.md.
import Foundation
import SQLiteSwift
import SQLiteSwiftModelContext
import SQLiteSwiftModels
import SQLiteSwiftTesting

struct RecipeFailure: Error { let id: String }

func check(_ id: String, _ condition: Bool) throws {
    guard condition else { throw RecipeFailure(id: id) }
    print("KIT_CHECK \(id) passed")
}

/// The SQLiteError a throwing operation produced, or nil if it succeeded.
func sqliteError<T>(_ operation: () async throws -> T) async -> SQLiteError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as SQLiteError {
        return error
    } catch {
        return nil
    }
}

/// A fresh directory for one recipe's database files.
func scratchPath(_ name: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-sqlite-kit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name).path
}

let taskMigrations = [
    SQLiteMigration(version: 1, name: "tasks", sql: """
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            version INTEGER NOT NULL DEFAULT 1,
            state TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        """)
]

// RECIPE open-migrate
func openAndMigrate() async throws {
    let path = try scratchPath("tasks.sqlite")
    let database = try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: taskMigrations)
    let version = try await database.read { tx throws(SQLiteError) in try tx.scalar("PRAGMA user_version") }
    try check("migrated", version == .integer(1))
    await database.close()

    // Older code must not open a file that newer migrations already changed.
    let refused = await sqliteError { try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: []) }
    try check("schema-too-new", refused?.code == .schemaTooNew)
}

// RECIPE bound-values
func boundValues() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: taskMigrations)
    let hostile = "x'); DROP TABLE tasks; --"
    try await database.write { tx throws(SQLiteError) in
        try tx.execute("INSERT INTO tasks (id, state, payload) VALUES (?, ?, ?)",
                       [.text(hostile), "working", .blob([1, 2, 3])])
    }
    let rows = try await database.read { tx throws(SQLiteError) in
        try tx.query("SELECT id, payload FROM tasks WHERE state = ?", ["working"],
                     limits: SQLiteQueryLimits(maxRows: 10))
    }
    try check("bound-text", rows.count == 1 && (try rows[0].text(0)) == hostile)
    try check("bound-blob", (try rows[0].blob(1)) == [1, 2, 3])
    let tooMany = await sqliteError {
        try await database.read { tx throws(SQLiteError) in
            try tx.query("SELECT 1 UNION ALL SELECT 2", limits: SQLiteQueryLimits(maxRows: 1))
        }
    }
    try check("never-truncated", tooMany?.code == .rowLimitExceeded)
    await database.close()
}

// RECIPE compare-and-set
func compareAndSet() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: taskMigrations)
    try await database.write { tx throws(SQLiteError) in
        try tx.execute("INSERT INTO tasks (id, state, payload) VALUES ('t1', 'working', x'')")
    }
    let results = try await database.write { tx throws(SQLiteError) in
        (try tx.compareAndSet(table: "tasks", id: "t1", expectedVersion: 1,
                              assignments: [SQLiteAssignment("state", "completed")]),
         try tx.compareAndSet(table: "tasks", id: "t1", expectedVersion: 1,
                              assignments: [SQLiteAssignment("state", "failed")]),
         try tx.compareAndSet(table: "tasks", id: "t1", expectedVersion: 2,
                              assignments: [SQLiteAssignment("state", "cancelled")],
                              alsoRequire: .notIn("state", ["completed", "failed", "cancelled"])),
         try tx.compareAndSet(table: "tasks", id: "nope", expectedVersion: 1))
    }
    try check("cas-updated", results.0 == .updated(newVersion: 2))
    try check("cas-conflict", results.1 == .conflict(currentVersion: 2))
    try check("cas-guard", results.2 == .guardFailed(currentVersion: 2))
    try check("cas-not-found", results.3 == .notFound)
    await database.close()
}

// RECIPE keyset-paging
func keysetPaging() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: taskMigrations)
    try await database.write { tx throws(SQLiteError) in
        for index in 0..<25 {
            try tx.execute("INSERT INTO tasks (id, state, payload) VALUES (?, 'working', x'')",
                           [.text(String(format: "t%02d", index))])
        }
    }
    var cursor: SQLiteKeysetCursor?
    var seen: [String] = []
    repeat {
        let page = try await database.read { [cursor] tx throws(SQLiteError) in
            try tx.queryPage(table: "tasks", columns: ["id"], keyColumns: ["id"], after: cursor,
                             filter: .equals("state", "working"), limit: 10)
        }
        for row in page.rows { seen.append(try row.text(0)) }
        cursor = page.nextCursor
    } while cursor != nil
    try check("paged-all", seen.count == 25 && seen == seen.sorted() && Set(seen).count == 25)
    await database.close()
}

// RECIPE operation-limits
func operationLimits() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: [])
    let endless = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"
    let late = await sqliteError {
        try await database.read(limits: SQLiteOperationLimits(timeout: .milliseconds(50))) { tx throws(SQLiteError) in
            try tx.scalar(endless)
        }
    }
    try check("deadline", late?.code == .deadlineExceeded)
    let costly = await sqliteError {
        try await database.read(limits: SQLiteOperationLimits(maxInstructions: 100_000)) { tx throws(SQLiteError) in
            try tx.scalar(endless)
        }
    }
    try check("instruction-budget", costly?.code == .instructionLimitExceeded)
    await database.close()
}

// RECIPE commit-outcome
func commitOutcome() async throws {
    let path = try scratchPath("outcome.sqlite")
    let database = try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: taskMigrations)
    let key = UUID().uuidString  // chosen before the write, so it can be looked up after
    let outcome = await database.writeReportingOutcome { tx throws(SQLiteError) in
        try tx.execute("INSERT INTO tasks (id, state, payload) VALUES (?, 'working', x'')", [.text(key)])
    }
    switch outcome {
    case .committed: try check("committed", true)
    case .notCommitted(let error): throw error
    case .unknown:
        // Only after .unknown: decide with a fresh read before telling anyone.
        _ = try await database.resolveCommit { tx throws(SQLiteError) in
            try tx.queryOne("SELECT 1 FROM tasks WHERE id = ?", [.text(key)]) != nil
        }
    }
    let durable = try await database.resolveCommit { tx throws(SQLiteError) in
        try tx.queryOne("SELECT 1 FROM tasks WHERE id = ?", [.text(key)]) != nil
    }
    try check("resolve-commit", durable)
    await database.close()
}

// RECIPE raw-bytes
func rawBytes() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: [])
    let stored: [UInt8] = [0x41, 0xFF, 0x00, 0x42]  // invalid UTF-8 with an embedded NUL
    let rows = try await database.write { tx throws(SQLiteError) in
        try tx.executeScript("CREATE TABLE docs (body TEXT)")
        try tx.executeRaw("INSERT INTO docs (body) VALUES (?)", [.text(stored)])
        return try tx.queryRaw("SELECT body FROM docs")
    }
    try check("raw-exact", rows.first?[0] == .text(stored))
    await database.close()
}

// RECIPE file-identity
func fileIdentity() async throws {
    let path = try scratchPath("identity.sqlite")
    var mine = SQLiteConfiguration(path: path)
    mine.fileIdentity = SQLiteFileIdentity(applicationID: 0x4B49_5431)  // "KIT1"
    await (try await SQLiteDatabase.open(mine, migrations: taskMigrations)).close()
    var other = SQLiteConfiguration(path: path)
    other.fileIdentity = SQLiteFileIdentity(applicationID: 0x4F54_4852)  // "OTHR"
    let refused = await sqliteError { try await SQLiteDatabase.open(other, migrations: taskMigrations) }
    try check("identity-refused", refused?.code == .fileIdentityMismatch)
}

// RECIPE error-codes
func errorCodes() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: taskMigrations)
    let insert: @Sendable (SQLiteTransaction) throws(SQLiteError) -> SQLiteChanges = { tx throws(SQLiteError) in
        try tx.execute("INSERT INTO tasks (id, state, payload) VALUES ('dup', 'working', x'')")
    }
    try await database.write(insert)
    do {
        try await database.write(insert)
        throw RecipeFailure(id: "duplicate-accepted")
    } catch SQLiteError.Code.constraint {
        try check("catch-by-code", true)
    }
    do throws(SQLiteError) {
        try await database.write(insert)
    } catch {
        switch error.code {
        case .busy: throw RecipeFailure(id: "unexpected-busy")
        case .constraint: try check("switch-with-default", true)
        default: throw error  // new codes can arrive in minor releases
        }
    }
    await database.close()
}

// RECIPE conformance-kit
func conformanceKit() async throws {
    // In a consumer this belongs in a test target: @Test(arguments: SQLiteConformanceKit.Check.allCases).
    let kit = SQLiteConformanceKit(migrations: taskMigrations)
    for item in [SQLiteConformanceKit.Check.migrations, .compareAndSetConflict, .fileIdentity] {
        let result = await kit.run(item)
        try check("conformance-\(item)", result.outcome == .passed)
    }
}

// RECIPE records
struct Article: SQLiteRecord {
    var id: String
    var title: String
    var publishedAt: Date?

    static let idColumn = SQLiteColumn("id", \Article.id, .text)
    static let titleColumn = SQLiteColumn("title", \Article.title, .text)
    static let publishedColumn = SQLiteColumn("published_at", \Article.publishedAt, .optional(.unixMilliseconds))

    static let descriptor = SQLiteRecordDescriptor(
        table: "articles", key: idColumn, columns: titleColumn, publishedColumn
    ) { row throws(SQLiteError) in
        Article(id: try row.value(idColumn), title: try row.value(titleColumn),
                publishedAt: try row.value(publishedColumn))
    }
}

let articleMigrations = [
    SQLiteMigration(version: 1, name: "articles", sql: """
        CREATE TABLE articles (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, published_at INTEGER,
            revision INTEGER NOT NULL CHECK (revision >= 1), incarnation BLOB NOT NULL);
        """),
    SQLiteModelSchema.migration(version: 2),
]

func records() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: articleMigrations)
    let draft = Article(id: "intro", title: "Hello", publishedAt: nil)
    let inserted = try await database.write { tx throws(SQLiteError) in
        try tx.verifySchema(for: Article.self)
        return try tx.insert(draft)
    }
    guard case .inserted(let first) = inserted else { throw RecipeFailure(id: "insert") }
    try check("record-inserted", first.version.revision == 1)

    let edited = Article(id: "intro", title: "Hello, again", publishedAt: nil)
    let (update, stale, duplicate) = try await database.write { tx throws(SQLiteError) in
        (try tx.update(edited, expecting: first.version),
         try tx.update(draft, expecting: first.version),  // read before the update
         try tx.insert(draft))
    }
    guard case .updated(let second) = update else { throw RecipeFailure(id: "update") }
    try check("record-updated", second.version.revision == 2 && second.value.title == "Hello, again")
    try check("record-stale-conflict", stale == .conflict(current: second))
    try check("record-duplicate-conflict", duplicate == .conflict(current: second))

    let gone = try await database.write { tx throws(SQLiteError) in
        (try tx.delete(Article.self, id: "intro", expecting: second.version),
         try tx.update(edited, expecting: second.version))
    }
    try check("record-deleted", gone.0 == .deleted && gone.1 == .missing)
    await database.close()
}

// RECIPE store-stream
func storeAndStream() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: articleMigrations)
    let store = SQLiteModelStore(database: database)
    let (initial, changes) = try await store.subscribe { tx throws(SQLiteError) in try tx.fetchAll(Article.self) }
    try check("stream-snapshot", initial.isEmpty)

    let a = Article(id: "a", title: "A", publishedAt: nil)
    let b = Article(id: "b", title: "B", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    guard case .committed = try await store.writeRecords([.insert(a), .insert(b)]) else {
        throw RecipeFailure(id: "batch-commit")
    }
    // All or nothing: the duplicate rolls the new insert back too.
    let c = Article(id: "c", title: "C", publishedAt: nil)
    guard case .rolledBack(let failure) = try await store.writeRecords([.insert(c), .insert(a)]) else {
        throw RecipeFailure(id: "batch-rollback")
    }
    try check("batch-rolled-back", failure.index == 1)

    var events = changes.makeAsyncIterator()
    guard case .committed(let batch) = await events.next() else { throw RecipeFailure(id: "stream-event") }
    try check("stream-event", batch.sequence == 1 && batch.changes.compactMap { $0.id(as: Article.self) } == ["a", "b"])
    let count = try await database.read { tx throws(SQLiteError) in try tx.fetchAll(Article.self).count }
    try check("batch-atomic", count == 2)
    await store.close()
}

// RECIPE editing-context
@MainActor
func editingContext() async throws {
    let database = try await SQLiteDatabase.open(.inMemory(), migrations: articleMigrations)
    let store = SQLiteModelStore(database: database)
    try await store.writeRecords([.insert(Article(id: "intro", title: "Hello", publishedAt: nil))])
    let mine = SQLiteModelContext(store: store), theirs = SQLiteModelContext(store: store)

    guard let article = try await mine.find(Article.self, id: "intro"),
          let other = try await theirs.find(Article.self, id: "intro")
    else { throw RecipeFailure(id: "find") }
    try check("one-handle", try await mine.find(Article.self, id: "intro") === article)

    other.value.title = "Theirs"
    try check("save-theirs", try await theirs.save() == .saved(count: 1))
    article.value.title = "Mine"
    guard case .conflict = try await mine.save() else { throw RecipeFailure(id: "conflict") }
    try check("conflict-keeps-edit", article.state == .conflicted && article.value.title == "Mine"
              && article.remote?.value.title == "Theirs")

    try article.keepLocal()  // explicit decision; the next save is still conditional
    try check("save-after-resolve", try await mine.save() == .saved(count: 1) && article.state == .clean)
    await store.close()
}

@main
enum SwiftSQLiteKit {
    static func main() async throws {
        try await openAndMigrate()
        try await boundValues()
        try await compareAndSet()
        try await keysetPaging()
        try await operationLimits()
        try await commitOutcome()
        try await rawBytes()
        try await fileIdentity()
        try await errorCodes()
        try await conformanceKit()
        try await records()
        try await storeAndStream()
        try await editingContext()
        print("KIT_RECIPES all passed")
    }
}
