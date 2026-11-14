// Local research spike; not a public API.
import Foundation
import Observation
import SQLiteSwift
import SQLiteSwiftTesting
import Synchronization
import Testing

private struct Article: Sendable, Equatable {
    let id: String
    var title: String
}
private struct Snapshot: Sendable, Equatable {
    let value: Article
    let revision: Int64
}
private enum HandleState: Equatable { case clean, dirty, saving, conflicted, deleted, indeterminate }

private struct Remote<Record: Sendable & Equatable>: Sendable, Equatable {
    let value: Record
    let revision: Int64
}

@MainActor @Observable
private final class ModelHandle<Record: Sendable & Equatable> {
    var value: Record {
        didSet {
            generation += 1
            switch state {
            case .clean, .dirty: state = .dirty
            case .deleted: state = .conflicted
            case .saving, .conflicted, .indeterminate: break
            }
        }
    }
    private(set) var state: HandleState = .clean
    private(set) var remote: Remote<Record>?
    @ObservationIgnored private(set) var baseline: Record
    @ObservationIgnored private(set) var revision: Int64
    @ObservationIgnored private(set) var generation: Int = 0
    init(_ value: Record, revision: Int64) { self.value = value; baseline = value; self.revision = revision }
    func restoreDirty() { state = .dirty }
    func markIndeterminate() { state = .indeterminate }
    func beginSave() -> (Record, Int) { state = .saving; return (value, generation) }
    func committed(_ outgoing: Record, revision: Int64, generation: Int) {
        baseline = outgoing; self.revision = revision; remote = nil
        state = self.generation == generation ? .clean : .dirty
    }
    func receive(_ newValue: Record?, revision newRevision: Int64) {
        guard let newValue else {
            remote = nil
            state = state == .clean ? .deleted : .conflicted
            return
        }
        guard newRevision > revision else { return }
        if state == .clean {
            value = newValue; baseline = newValue; revision = newRevision; remote = nil; state = .clean
        } else {
            remote = Remote(value: newValue, revision: newRevision); state = .conflicted
        }
    }
    // Explicitly keep the local value against the latest known remote revision.
    func keepLocal() {
        guard state == .conflicted, let remote else { return }
        baseline = remote.value; revision = remote.revision; self.remote = nil; state = .dirty
    }
    // Explicitly discard local changes and use the latest known remote revision.
    func useRemote() {
        guard state == .conflicted, let remote else { return }
        value = remote.value; baseline = remote.value; revision = remote.revision
        self.remote = nil; state = .clean
    }
}

private enum SaveResult: Sendable {
    case committed
    case conflict(id: String, remote: Snapshot?)
}

private enum Expectation: Sendable { case absent, revision(Int64) }
private enum ConditionalResult: Sendable, Equatable {
    case inserted, updated(Int64), deleted, conflict(Snapshot?), missing, retired
}

// The package owns the connection threads; this actor owns the experimental store API.
private enum SaveFault: Sendable { case none, unknownBefore, unknownAfter }
private actor ArticleStore {
    let database: SQLiteDatabase
    private var fault: SaveFault
    init(_ database: SQLiteDatabase, fault: SaveFault = .none) { self.database = database; self.fault = fault }
    func insert(_ article: Article) async throws {
        try await database.write { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO articles VALUES (?, ?, 1)", [.text(article.id), .text(article.title)])
        }
    }
    func update(_ snapshot: Snapshot) async throws -> SQLiteCompareAndSetResult {
        try await database.write { tx throws(SQLiteError) in
            try tx.compareAndSet(table: "articles", versionColumn: "revision", id: .text(snapshot.value.id),
                expectedVersion: snapshot.revision, assignments: [SQLiteAssignment("title", .text(snapshot.value.title))])
        }
    }
    // `.absent` creates only; `.revision` updates only. Neither blindly replaces.
    func put(_ value: Article, expecting: Expectation) async throws -> ConditionalResult {
        try await database.write { tx throws(SQLiteError) in
            switch expecting {
            case .absent:
                if let row = try tx.queryOne("SELECT title, revision FROM articles WHERE id = ?", [.text(value.id)]) {
                    return .conflict(Snapshot(value: Article(id: value.id, title: try row.text(0)), revision: try row.integer(1)))
                }
                if try tx.queryOne("SELECT 1 FROM used_article_ids WHERE id = ?", [.text(value.id)]) != nil { return .retired }
                try tx.execute("INSERT INTO articles VALUES (?, ?, 1)", [.text(value.id), .text(value.title)])
                return .inserted
            case .revision(let revision):
                let result = try tx.compareAndSet(table: "articles", versionColumn: "revision", id: .text(value.id), expectedVersion: revision, assignments: [SQLiteAssignment("title", .text(value.title))])
                switch result {
                case .updated(let newRevision): return .updated(newRevision)
                case .notFound: return .missing
                case .conflict, .guardFailed: break
                }
            }
            let row = try tx.queryOne("SELECT title, revision FROM articles WHERE id = ?", [.text(value.id)])
            guard let row else { return .missing }
            return .conflict(Snapshot(value: Article(id: value.id, title: try row.text(0)), revision: try row.integer(1)))
        }
    }
    func delete(_ id: String, revision: Int64) async throws -> ConditionalResult {
        try await database.write { tx throws(SQLiteError) in
            let changed = try tx.execute("DELETE FROM articles WHERE id = ? AND revision = ?", [.text(id), .integer(revision)]).changedRows
            if changed == 1 { return .deleted }
            guard let row = try tx.queryOne("SELECT title, revision FROM articles WHERE id = ?", [.text(id)]) else { return .missing }
            return .conflict(Snapshot(value: Article(id: id, title: try row.text(0)), revision: try row.integer(1)))
        }
    }
    func save(_ snapshots: [Snapshot], marker: String) async throws -> SaveResult {
        // Test-only injection approximates the two durable outcomes of an unknown commit.
        let injected = fault; fault = .none
        if case .unknownBefore = injected { throw SQLiteError.commitOutcomeUnknown(.misuse("injected")) }
        let outcome = try await database.writeOrRollback { tx throws(SQLiteError) in
            for snapshot in snapshots {
                let result = try tx.compareAndSet(table: "articles", versionColumn: "revision",
                    id: .text(snapshot.value.id), expectedVersion: snapshot.revision,
                    assignments: [SQLiteAssignment("title", .text(snapshot.value.title))])
                guard case .updated = result else {
                    let row = try tx.queryOne("SELECT title, revision FROM articles WHERE id = ?", [.text(snapshot.value.id)])
                    let remote: Snapshot?
                    if let row {
                        remote = Snapshot(value: Article(id: snapshot.value.id, title: try row.text(0)), revision: try row.integer(1))
                    } else { remote = nil }
                    return .rollback(SaveResult.conflict(id: snapshot.value.id, remote: remote))
                }
            }
            try tx.execute("INSERT INTO save_markers VALUES (?)", [.text(marker)])
            return .commit(SaveResult.committed)
        }
        if case .committed = outcome, case .unknownAfter = injected {
            throw SQLiteError.commitOutcomeUnknown(.misuse("injected"))
        }
        return outcome
    }
    func resolve(marker: String) async throws -> Bool {
        try await database.resolveCommit { tx throws(SQLiteError) in
            try tx.queryOne("SELECT 1 FROM save_markers WHERE id = ?", [.text(marker)]) != nil
        }
    }
    func load(_ id: String) async throws -> Snapshot? {
        try await database.read { tx throws(SQLiteError) in
            guard let row = try tx.queryOne("SELECT title, revision FROM articles WHERE id = ?", [.text(id)]) else { return nil }
            return Snapshot(value: Article(id: id, title: try row.text(0)), revision: try row.integer(1))
        }
    }
}

private enum ContextError: Error { case saving, conflict, indeterminate, refreshing }
@MainActor private final class ArticleContext {
    let store: ArticleStore
    private var handles: [String: ModelHandle<Article>] = [:]
    private var saving = false
    private var refreshing: Set<String> = []
    private typealias Captured = (ModelHandle<Article>, Snapshot, Int)
    private var unknown: (marker: String, pending: [Captured])?
    // An injectable suspension point lets tests control save reentrancy without sleeps.
    private let beforeWrite: @Sendable () async -> Void
    init(store: ArticleStore, beforeWrite: @escaping @Sendable () async -> Void = {}) {
        self.store = store; self.beforeWrite = beforeWrite
    }
    func find(_ id: String) async throws -> ModelHandle<Article>? {
        if let existing = handles[id] { return existing }
        guard let snapshot = try await store.load(id) else { return nil }
        // Another find can complete while the actor is suspended.
        if let existing = handles[id] { return existing }
        let handle = ModelHandle(snapshot.value, revision: snapshot.revision)
        handles[id] = handle
        return handle
    }
    func save() async throws {
        guard !saving else { throw ContextError.saving }
        guard !handles.values.contains(where: { $0.state == .indeterminate }) else { throw ContextError.indeterminate }
        guard !handles.values.contains(where: { $0.state == .conflicted }) else { throw ContextError.conflict }
        saving = true
        defer { saving = false }
        let pending = handles.values.filter { $0.state == .dirty }.map { handle in
            let (value, generation) = handle.beginSave()
            return (handle, Snapshot(value: value, revision: handle.revision), generation)
        }
        guard !pending.isEmpty else { return }
        let marker = UUID().uuidString
        do {
            await beforeWrite()
            let result = try await store.save(pending.map { $0.1 }, marker: marker)
            switch result {
            case .committed:
                for (handle, snapshot, generation) in pending {
                    handle.committed(snapshot.value, revision: snapshot.revision + 1, generation: generation)
                }
            case .conflict(let id, let remote):
                for (handle, snapshot, _) in pending {
                    if snapshot.value.id == id {
                        handle.receive(remote?.value, revision: remote?.revision ?? snapshot.revision)
                    } else { handle.restoreDirty() }
                }
                throw ContextError.conflict
            }
        } catch let error as SQLiteError where error.code == .commitOutcomeUnknown {
            unknown = (marker, pending)
            for (handle, _, _) in pending { handle.markIndeterminate() }
            throw error
        } catch {
            for (handle, _, _) in pending where handle.state == .saving { handle.restoreDirty() }
            throw error
        }
    }
    func resolveUnknown() async throws {
        guard !saving else { throw ContextError.saving }
        guard let unresolved = unknown else { return }
        saving = true
        defer { saving = false }
        let committed = try await store.resolve(marker: unresolved.marker)
        for (handle, snapshot, generation) in unresolved.pending {
            if committed { handle.committed(snapshot.value, revision: snapshot.revision + 1, generation: generation) }
            else { handle.restoreDirty() }
        }
        unknown = nil
    }
    func refresh(_ id: String) async throws {
        guard !saving else { throw ContextError.saving }
        guard let handle = handles[id] else { return }
        guard handle.state != .indeterminate else { throw ContextError.indeterminate }
        guard refreshing.insert(id).inserted else { throw ContextError.refreshing }
        defer { refreshing.remove(id) }
        let originalRevision = handle.revision
        let remote = try await store.load(id)
        guard !saving else { throw ContextError.saving }
        guard handle.state != .indeterminate else { throw ContextError.indeterminate }
        guard handle.revision == originalRevision else { return }
        handle.receive(remote?.value, revision: remote?.revision ?? handle.revision)
    }
}

private actor SaveGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        if released { return }
        arrived = true
        arrivalWaiter?.resume(); arrivalWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

@Suite("Local snapshot and observation spike")
struct ObservableSpikeTests {
    static let migrations = [SQLiteMigration(version: 1, name: "articles", sql: """
        CREATE TABLE articles(id TEXT PRIMARY KEY, title TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 1));
        CREATE TABLE used_article_ids(id TEXT PRIMARY KEY);
        CREATE TRIGGER article_id_never_reused BEFORE INSERT ON articles BEGIN
            SELECT RAISE(ABORT, 'article identity already used') WHERE EXISTS (SELECT 1 FROM used_article_ids WHERE id = NEW.id);
            INSERT INTO used_article_ids(id) VALUES (NEW.id);
        END;
        CREATE TABLE save_markers(id TEXT PRIMARY KEY);
        CREATE TABLE unmanaged(id TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)]

    @Test func casAndRollback() async throws {
        let dir = try SQLiteTemporaryDirectory()
        let config = SQLiteConfiguration(path: dir.file("spike.sqlite"))
        let first = try await SQLiteDatabase.open(config, migrations: Self.migrations)
        let second = try await SQLiteDatabase.open(config, migrations: Self.migrations)
        try await first.write { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO articles VALUES (?, ?, 1)", ["a", "original"])
            try tx.execute("INSERT INTO unmanaged VALUES (?, ?)", ["x", "raw"])
        }
        let result = try await first.write { tx throws(SQLiteError) in
            try tx.compareAndSet(table: "articles", versionColumn: "revision", id: "a", expectedVersion: 1,
                                 assignments: [SQLiteAssignment("title", "committed")])
        }
        #expect(result == .updated(newVersion: 2))
        let stale = try await second.write { tx throws(SQLiteError) in
            try tx.compareAndSet(table: "articles", versionColumn: "revision", id: "a", expectedVersion: 1,
                                 assignments: [SQLiteAssignment("title", "local")])
        }
        #expect(stale == .conflict(currentVersion: 2))
        let rolledBack = try await first.writeOrRollback { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO articles VALUES ('b', 'temporary', 1)")
            let conflict = try tx.compareAndSet(table: "articles", versionColumn: "revision", id: "a", expectedVersion: 1)
            return conflict == .updated(newVersion: 2) ? .commit(false) : .rollback(true)
        }
        #expect(rolledBack)
        let values = try await second.read { tx throws(SQLiteError) in
            (try tx.query("SELECT id FROM articles ORDER BY id").count, try tx.queryOne("SELECT value FROM unmanaged WHERE id = 'x'")?.text(0))
        }
        #expect(values.0 == 1)
        #expect(values.1 == "raw")
        let bInserted = try await first.write { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO articles VALUES ('b', 'after rollback', 1)").changedRows
        }
        #expect(bInserted == 1) // Rolled-back insertion must not retire the identity.
        let deletion = try await second.write { tx throws(SQLiteError) in
            try tx.execute("DELETE FROM articles WHERE id = ? AND revision = ?", ["a", 2]).changedRows
        }
        #expect(deletion == 1)
        let missing = try await first.write { tx throws(SQLiteError) in
            try tx.compareAndSet(table: "articles", versionColumn: "revision", id: "a", expectedVersion: 2)
        }
        #expect(missing == .notFound)
        await first.close(); await second.close()
    }

    @Test func conditionalPutAndDelete() async throws {
        let db = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(db)
        let a = Article(id: "a", title: "initial")
        #expect(try await store.put(a, expecting: .absent) == .inserted)
        let initial = Snapshot(value: a, revision: 1)
        #expect(try await store.put(Article(id: "a", title: "duplicate"), expecting: .absent) == .conflict(initial))
        #expect(try await store.put(Article(id: "missing", title: "x"), expecting: .revision(1)) == .missing)
        #expect(try await store.put(Article(id: "a", title: "next"), expecting: .revision(1)) == .updated(2))
        let updated = Snapshot(value: Article(id: "a", title: "next"), revision: 2)
        #expect(try await store.put(a, expecting: .revision(1)) == .conflict(updated))
        #expect(try await store.delete("a", revision: 1) == .conflict(updated))
        #expect(try await store.delete("a", revision: 2) == .deleted)
        #expect(try await store.delete("a", revision: 2) == .missing)
        #expect(try await store.put(Article(id: "a", title: "reused"), expecting: .absent) == .retired)
        #expect(try await store.put(a, expecting: .revision(1)) == .missing)
        let rawReuseError = await caught { try await db.write { tx throws(SQLiteError) in
            try tx.execute("INSERT INTO articles VALUES (?, ?, 1)", ["a", "reused"])
        } }
        #expect(rawReuseError != nil)
        let replaceReuseError = await caught { try await db.write { tx throws(SQLiteError) in
            try tx.execute("INSERT OR REPLACE INTO articles VALUES (?, ?, 1)", ["a", "reused"])
        } }
        #expect(replaceReuseError != nil)
        #expect(try await store.load("a") == nil)
        await db.close()
    }

    @Test func concurrentStores() async throws {
        let dir = try SQLiteTemporaryDirectory()
        let config = SQLiteConfiguration(path: dir.file("concurrent.sqlite"))
        let first = try await SQLiteDatabase.open(config, migrations: Self.migrations)
        let second = try await SQLiteDatabase.open(config, migrations: Self.migrations)
        let a = ArticleStore(first), b = ArticleStore(second)
        try await a.insert(Article(id: "a", title: "base"))
        async let one = a.update(Snapshot(value: Article(id: "a", title: "one"), revision: 1))
        async let two = b.update(Snapshot(value: Article(id: "a", title: "two"), revision: 1))
        let outcomes = try await [one, two]
        #expect(outcomes.filter { $0 == .updated(newVersion: 2) }.count == 1)
        #expect(outcomes.filter { $0 == .conflict(currentVersion: 2) }.count == 1)
        #expect(try await a.load("a")?.revision == 2)
        await first.close(); await second.close()
    }

    @Test @MainActor func contextIdentitySaveAndRefresh() async throws {
        let database = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(database)
        try await store.insert(Article(id: "a", title: "base"))
        let first = ArticleContext(store: store), second = ArticleContext(store: store)
        let a = try #require(await first.find("a"))
        let again = try #require(await first.find("a"))
        let b = try #require(await second.find("a"))
        #expect(a === again)
        a.value.title = "saved"
        #expect(try await store.load("a")?.value.title == "base")
        try await first.save()
        #expect(a.state == .clean)
        try await second.refresh("a")
        #expect(b.value.title == "saved")
        b.value.title = "local"
        a.value.title = "remote"
        try await first.save()
        try await second.refresh("a")
        #expect(b.value.title == "local")
        #expect(b.state == .conflicted)
        await database.close()
    }

    @Test @MainActor func conflictRollsBackBatchAndCanResolve() async throws {
        let db = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(db)
        try await store.insert(Article(id: "a", title: "a0"))
        try await store.insert(Article(id: "b", title: "b0"))
        let local = ArticleContext(store: store)
        let a = try #require(await local.find("a"))
        let b = try #require(await local.find("b"))
        a.value.title = "a-local"; b.value.title = "b-local"
        #expect(try await store.update(Snapshot(value: Article(id: "b", title: "b-remote"), revision: 1)) == .updated(newVersion: 2))
        do { try await local.save(); Issue.record("Expected conflict") } catch ContextError.conflict { }
        #expect(a.state == .dirty)
        #expect(b.state == .conflicted)
        #expect(b.baseline.title == "b0")
        #expect(b.value.title == "b-local")
        #expect(b.remote?.value.title == "b-remote")
        #expect(b.remote?.revision == 2)
        #expect(try await store.load("a")?.value.title == "a0")
        b.keepLocal()
        try await local.save()
        #expect(try await store.load("a")?.value.title == "a-local")
        #expect(try await store.load("b")?.value.title == "b-local")
        #expect(try await store.load("b")?.revision == 3)
        await db.close()
    }

    @Test @MainActor func editDuringAwaitedSaveAndOverlap() async throws {
        let db = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(db)
        try await store.insert(Article(id: "a", title: "base"))
        let gate = SaveGate()
        let context = ArticleContext(store: store, beforeWrite: { await gate.pause() })
        let handle = try #require(await context.find("a"))
        handle.value.title = "first"
        let saving = Task { @MainActor in try await context.save() }
        await gate.waitUntilArrived()
        handle.value.title = "later"
        do { try await context.save(); Issue.record("Expected overlapping save to fail") } catch ContextError.saving { }
        await gate.release()
        try await saving.value
        #expect(handle.state == .dirty)
        #expect(handle.value.title == "later")
        #expect(handle.baseline.title == "first")
        #expect(handle.revision == 2)
        #expect(try await store.load("a")?.value.title == "first")
        try await context.save()
        #expect(handle.state == .clean)
        #expect(try await store.load("a")?.value.title == "later")
        #expect(handle.revision == 3)
        await db.close()
    }

    @Test @MainActor func cancelledSavePreservesEdits() async throws {
        let db = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(db)
        try await store.insert(Article(id: "a", title: "base"))
        let gate = SaveGate()
        let context = ArticleContext(store: store, beforeWrite: { await gate.pause() })
        let handle = try #require(await context.find("a"))
        handle.value.title = "local"
        let saving = Task { @MainActor in try await context.save() }
        await gate.waitUntilArrived()
        saving.cancel()
        await gate.release()
        do { try await saving.value; Issue.record("Expected cancellation") } catch { }
        #expect(handle.state == .dirty)
        #expect(handle.value.title == "local")
        #expect(try await store.load("a")?.value.title == "base")
        try await context.save()
        #expect(handle.state == .clean)
        #expect(try await store.load("a")?.value.title == "local")
        await db.close()
    }

    @Test @MainActor func unknownCommitResolution() async throws {
        for fault in [SaveFault.unknownBefore, .unknownAfter] {
            let dir = try SQLiteTemporaryDirectory()
            let db = try await SQLiteDatabase.open(SQLiteConfiguration(path: dir.file("unknown.sqlite")), migrations: Self.migrations)
            let store = ArticleStore(db, fault: fault)
            try await store.insert(Article(id: "a", title: "base"))
            let context = ArticleContext(store: store)
            let handle = try #require(await context.find("a"))
            handle.value.title = "first"
            do { try await context.save(); Issue.record("Expected unknown outcome") }
            catch let error as SQLiteError { #expect(error.code == .commitOutcomeUnknown) }
            #expect(handle.state == .indeterminate)
            handle.value.title = "later"
            do { try await context.save(); Issue.record("Expected indeterminate block") } catch ContextError.indeterminate { }
            try await context.resolveUnknown()
            #expect(handle.state == .dirty)
            #expect(handle.value.title == "later")
            switch fault {
            case .unknownBefore:
                #expect(handle.baseline.title == "base")
                #expect(handle.revision == 1)
            case .unknownAfter:
                #expect(handle.baseline.title == "first")
                #expect(handle.revision == 2)
            case .none: Issue.record("Unexpected fault")
            }
            try await context.save()
            #expect(handle.state == .clean)
            #expect(try await store.load("a")?.value.title == "later")
            await db.close()
        }
    }

    @Test @MainActor func failedResolutionRemainsIndeterminate() async throws {
        let dir = try SQLiteTemporaryDirectory()
        let db = try await SQLiteDatabase.open(SQLiteConfiguration(path: dir.file("closed.sqlite")), migrations: Self.migrations)
        let store = ArticleStore(db, fault: .unknownAfter)
        try await store.insert(Article(id: "a", title: "base"))
        let context = ArticleContext(store: store)
        let handle = try #require(await context.find("a"))
        handle.value.title = "local"
        do { try await context.save(); Issue.record("Expected unknown outcome") } catch let error as SQLiteError { #expect(error.code == .commitOutcomeUnknown) }
        await db.close()
        do { try await context.resolveUnknown(); Issue.record("Expected resolution failure") } catch let error as SQLiteError { #expect(error.code == .closed) }
        #expect(handle.state == .indeterminate)
        #expect(handle.value.title == "local")
        do { try await context.save(); Issue.record("Expected indeterminate block") } catch ContextError.indeterminate { }
    }

    @Test @MainActor func unknownCommitThenRemoteWriteDoesNotOverwrite() async throws {
        let dir = try SQLiteTemporaryDirectory()
        let db = try await SQLiteDatabase.open(SQLiteConfiguration(path: dir.file("unknown-remote.sqlite")), migrations: Self.migrations)
        let store = ArticleStore(db, fault: .unknownAfter)
        try await store.insert(Article(id: "a", title: "base"))
        let context = ArticleContext(store: store)
        let handle = try #require(await context.find("a"))
        handle.value.title = "committed"
        do { try await context.save(); Issue.record("Expected unknown outcome") } catch let error as SQLiteError { #expect(error.code == .commitOutcomeUnknown) }
        handle.value.title = "later local"
        #expect(try await store.update(Snapshot(value: Article(id: "a", title: "remote"), revision: 2)) == .updated(newVersion: 3))
        try await context.resolveUnknown()
        #expect(handle.state == .dirty)
        do { try await context.save(); Issue.record("Expected conflict") } catch ContextError.conflict { }
        #expect(handle.value.title == "later local")
        #expect(handle.baseline.title == "committed")
        #expect(handle.remote?.value.title == "remote")
        #expect(handle.remote?.revision == 3)
        #expect(try await store.load("a")?.value.title == "remote")
        await db.close()
    }

    @Test @MainActor func remoteDeletionDoesNotResurrect() async throws {
        let db = try await SQLiteDatabase.open(.inMemory(), migrations: Self.migrations)
        let store = ArticleStore(db)
        try await store.insert(Article(id: "a", title: "base"))
        let context = ArticleContext(store: store)
        let handle = try #require(await context.find("a"))
        handle.value.title = "local"
        try await db.write { tx throws(SQLiteError) in
            try tx.execute("DELETE FROM articles WHERE id = ? AND revision = ?", ["a", 1])
        }
        do { try await context.save(); Issue.record("Expected missing-row conflict") } catch ContextError.conflict { }
        #expect(handle.state == .conflicted)
        #expect(handle.remote == nil)
        #expect(handle.value.title == "local")
        handle.keepLocal()
        #expect(handle.state == .conflicted)
        #expect(try await store.load("a") == nil)
        await db.close()
    }

    @Test @MainActor func nestedObservationAndGeneration() {
        let handle = ModelHandle(Article(id: "a", title: "original"), revision: 1)
        let changes = Mutex(0)
        withObservationTracking { _ = handle.value.title } onChange: { changes.withLock { $0 += 1 } }
        handle.value.title = "first"
        #expect(changes.withLock { $0 } == 1)
        #expect(handle.state == .dirty)
        let (outgoing, generation) = handle.beginSave()
        handle.value.title = "later"
        handle.committed(outgoing, revision: 2, generation: generation)
        #expect(handle.value.title == "later")
        #expect(handle.baseline.title == "first")
        #expect(handle.state == .dirty)
        handle.receive(Article(id: "a", title: "remote"), revision: 3)
        #expect(handle.state == .conflicted)
        #expect(handle.value.title == "later")
    }

    @Test @MainActor func cleanRefreshAndDeletion() {
        let handle = ModelHandle(Article(id: "a", title: "old"), revision: 1)
        handle.receive(Article(id: "a", title: "new"), revision: 2)
        #expect(handle.value.title == "new")
        #expect(handle.state == .clean)
        handle.receive(nil, revision: 3)
        #expect(handle.state == .deleted)
    }
}
