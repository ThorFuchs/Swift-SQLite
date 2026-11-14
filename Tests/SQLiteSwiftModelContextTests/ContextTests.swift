// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import Observation
@testable import SQLiteSwift
@testable import SQLiteSwiftModelContext
import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

@MainActor
@Suite("G3: editing context, handle states and saves")
struct ContextTests {
    // MARK: Identity

    @Test("One handle per record, also for concurrent finds; a missing key is nil")
    func oneHandlePerRecord() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            async let first = context.find(Note.self, id: "a")
            async let second = context.find(Note.self, id: "a")
            let (x, y) = try await (first, second)
            let a = try #require(x)
            #expect(a === y)
            #expect(try await context.find(Note.self, id: "a") === a)
            #expect(try await context.find(Note.self, id: "zzz") == nil)
            #expect(a.state == .clean && a.baseline?.version.revision == 1)

            let other = SQLiteModelContext(store: SQLiteModelStore(database: database))
            #expect(try await other.find(Note.self, id: "a") !== a)  // context-local, never global
        }
    }

    // MARK: Clean, dirty, saved

    @Test("Edit, save, and the baseline takes the version the database returned")
    func editAndSave() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let c = try #require(try await context.find(Counter.self, id: 1))
            a.value.title = "A2"
            c.value.count += 1
            #expect(a.state == .dirty && c.state == .dirty && a.hasUnsavedChanges)
            #expect(try await context.save() == .saved(count: 2))
            #expect(a.state == .clean && c.state == .clean && !a.hasUnsavedChanges)
            let row = try #require(try await stored(database, note: "a"))
            #expect(a.baseline == row)
            #expect(row.version.revision == 2 && row.value.title == "A2")
            #expect(try await context.save() == .saved(count: 0))
        }
    }

    @Test("A remote row applied to a clean handle is not a local edit")
    func remoteIsNotAnEdit() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let generation = a.editGeneration
            let other = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let remote = try #require(try await other.find(Note.self, id: "a"))
            remote.value.title = "remote"
            try await other.save()

            let observed = ObservedFlag()
            withObservationTracking { _ = a.value } onChange: { observed.set() }
            try await context.refresh(a)
            #expect(observed.value)              // views see the new value
            #expect(a.value.title == "remote")
            #expect(a.state == .clean)           // but nothing to save
            #expect(a.editGeneration == generation)
            #expect(try await context.save() == .saved(count: 0))
        }
    }

    // MARK: Saving with later edits and overlapping saves

    @Test("Edits made while a save is suspended are kept and stay dirty")
    func editDuringSave() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let reached = Gate(), release = Gate()
            context.beforeWriteForTesting = { reached.open(); await release.wait() }
            a.value.title = "first"
            let save = Task { try await context.save() }
            await reached.wait()
            #expect(a.state == .saving && !a.hasUnsavedChanges)
            a.value.title = "second"             // edited while the save is in flight
            #expect(a.state == .saving && a.hasUnsavedChanges)
            release.open()
            #expect(try await save.value == .saved(count: 1))

            #expect(a.state == .dirty)
            #expect(a.value.title == "second")
            #expect(a.baseline?.value.title == "first" && a.baseline?.version.revision == 2)
            context.beforeWriteForTesting = nil
            #expect(try await context.save() == .saved(count: 1))
            #expect(a.state == .clean && a.baseline?.version.revision == 3)
            #expect(try await stored(database, note: "a")?.value.title == "second")
        }
    }

    @Test("A second save waits for the first instead of overlapping it")
    func savesAreSerialized() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let b = try #require(try await context.find(Note.self, id: "b"))
            let reached = Gate(), release = Gate()
            context.beforeWriteForTesting = { reached.open(); await release.wait() }
            a.value.title = "a1"
            let first = Task { try await context.save() }
            await reached.wait()
            context.beforeWriteForTesting = nil
            b.value.title = "b1"
            let second = Task { try await context.save() }
            await Task.yield()
            #expect(b.state == .dirty)           // not captured by the running save
            release.open()
            #expect(try await first.value == .saved(count: 1))
            #expect(try await second.value == .saved(count: 1))
            #expect(a.state == .clean && b.state == .clean)
        }
    }

    // MARK: Conflicts

    @Test("A stale save conflicts, rolls back, and doesn't blame the other handles")
    func conflictDoesNotBlameOthers() async throws {
        try await withContextDatabase { database in
            let mine = SQLiteModelContext(store: SQLiteModelStore(database: database)), theirs = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await mine.find(Note.self, id: "a"))
            let b = try #require(try await mine.find(Note.self, id: "b"))
            let c = try #require(try await mine.find(Counter.self, id: 1))
            let remote = try #require(try await theirs.find(Note.self, id: "b"))
            remote.value.title = "theirs"
            try await theirs.save()

            a.value.title = "mine a"
            b.value.title = "mine b"
            c.value.count = 5
            let result = try await mine.save()
            guard case .conflict(let conflict) = result else { Issue.record("got \(result)"); return }
            #expect(conflict.table == "notes" && conflict.id == "b")
            #expect(b.state == .conflicted)
            #expect(b.remote?.value.title == "theirs" && b.remote?.version.revision == 2)
            #expect(b.value.title == "mine b" && b.baseline?.version.revision == 1)
            #expect(a.state == .dirty && c.state == .dirty)          // not blamed
            #expect(try await stored(database, note: "a")?.version.revision == 1)  // rolled back

            // Explicit resolution: keep mine on top of theirs, still conditional.
            try b.keepLocal()
            #expect(b.state == .dirty && b.baseline?.version.revision == 2)
            #expect(try await mine.save() == .saved(count: 3))
            #expect(try await stored(database, note: "b")?.value.title == "mine b")
            #expect(b.baseline?.version.revision == 3)
        }
    }

    @Test("useRemote and discard drop local edits; resolution needs a conflict")
    func useRemoteAndDiscard() async throws {
        try await withContextDatabase { database in
            let mine = SQLiteModelContext(store: SQLiteModelStore(database: database)), theirs = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await mine.find(Note.self, id: "a"))
            #expect(await caught { try a.useRemote() }?.code == .misuse)
            #expect(await caught { try a.keepLocal() }?.code == .misuse)
            let remote = try #require(try await theirs.find(Note.self, id: "a"))
            remote.value.body = "theirs"
            try await theirs.save()

            a.value.title = "mine"
            try await mine.refresh(a)           // a dirty handle keeps its edits…
            #expect(a.state == .conflicted && a.value.title == "mine")
            try a.useRemote()                   // …until told otherwise
            #expect(a.state == .clean && a.value == remote.value && a.baseline == remote.baseline)

            a.value.title = "scratch"
            try a.discard()
            #expect(a.state == .clean && a.value == remote.value)
        }
    }

    @Test("A remote deletion is a conflict and never becomes an insert")
    func remoteDeletionDoesNotResurrect() async throws {
        try await withContextDatabase { database in
            let mine = SQLiteModelContext(store: SQLiteModelStore(database: database)), theirs = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await mine.find(Note.self, id: "a"))
            let b = try #require(try await mine.find(Note.self, id: "b"))
            let ra = try #require(try await theirs.find(Note.self, id: "a"))
            let rb = try #require(try await theirs.find(Note.self, id: "b"))
            try theirs.delete(ra)
            try theirs.delete(rb)
            #expect(try await theirs.save() == .saved(count: 2))
            #expect(ra.state == .deleted && !theirs.contains(Note.self, id: "a"))

            a.value.title = "edited after remote delete"
            let result = try await mine.save()
            guard case .conflict(let conflict) = result else { Issue.record("got \(result)"); return }
            #expect(conflict.found == .missing)
            #expect(a.state == .conflicted && a.isDeletedRemotely && a.remote == nil)
            #expect(await caught { try a.keepLocal() }?.code == .misuse)
            try a.discard()
            #expect(a.state == .deleted && !mine.contains(Note.self, id: "a"))
            #expect(try await stored(database, note: "a") == nil)

            try await mine.refresh(b)           // a clean handle shows the deletion
            #expect(b.state == .deleted && b.isDeletedRemotely)
            #expect(try await mine.find(Note.self, id: "b") == nil)
        }
    }

    // MARK: Insert and delete

    @Test("Insert and delete through the context; a taken key conflicts")
    func insertAndDelete() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let n = try context.insert(Note(id: "n", title: "new", body: nil))
            #expect(n.state == .dirty && n.baseline == nil)
            #expect(await caught { try context.insert(Note(id: "n", title: "again", body: nil)) }?.code == .misuse)
            #expect(try await context.save() == .saved(count: 1))
            let row = try #require(try await stored(database, note: "n"))
            #expect(n.state == .clean && n.baseline == row && row.version.revision == 1)

            try context.delete(n)
            #expect(n.state == .dirty && n.isMarkedForDeletion)
            #expect(try await context.save() == .saved(count: 1))
            #expect(n.state == .deleted && !context.contains(Note.self, id: "n"))
            #expect(try await stored(database, note: "n") == nil)

            let clash = try context.insert(Note(id: "a", title: "clash", body: nil))
            let result = try await context.save()
            guard case .conflict(let conflict) = result else { Issue.record("got \(result)"); return }
            #expect(conflict.id == "a" && clash.state == .conflicted && clash.remote?.value.title == "A")
            try clash.keepLocal()               // explicitly overwrite that row, conditionally
            #expect(try await context.save() == .saved(count: 1))
            #expect(try await stored(database, note: "a")?.value.title == "clash")

            let draft = try context.insert(Note(id: "d", title: "draft", body: nil))
            try draft.discard()
            #expect(draft.state == .deleted && !context.contains(Note.self, id: "d"))
        }
    }

    @Test("A changed key is refused and the save writes nothing")
    func keyCannotChange() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let b = try #require(try await context.find(Note.self, id: "b"))
            b.value.title = "fine"
            a.value.id = "moved"
            #expect(await caught { try await context.save() }?.code == .invalidArgument)
            #expect(a.state == .dirty && b.state == .dirty)
            #expect(try await stored(database, note: "b")?.value.title == "B")
        }
    }

    // MARK: Cancellation

    @Test("Cancelled before the save starts: nothing is written, edits stay")
    func cancelBeforeSave() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            a.value.title = "never"
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await context.save()
            }
            let error = await caught { try await task.value }
            #expect(error?.code == .interrupted)
            #expect(a.state == .dirty && a.value.title == "never")
            #expect(try await stored(database, note: "a")?.version.revision == 1)
        }
    }

    @Test("Cancelled while suspended before the write: nothing is written, edits stay")
    func cancelDuringPreWriteSuspension() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let reached = Gate(), release = Gate()
            context.beforeWriteForTesting = { reached.open(); await release.wait() }
            a.value.title = "never"
            let task = Task { try await context.save() }
            await reached.wait()
            #expect(a.state == .saving)
            task.cancel()
            release.open()
            #expect(await caught { try await task.value }?.code == .interrupted)
            #expect(a.state == .dirty && a.value.title == "never")
            #expect(try await stored(database, note: "a")?.version.revision == 1)
            #expect(try await markerCount(database) == .integer(0))
        }
    }

    @Test("Cancelled inside the transaction: rolled back, not unknown, edits stay")
    func cancelInsideTransaction() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let reached = Signal()
            let release = DispatchSemaphore(value: 0)
            context.inTransactionForTesting = { (_) throws(SQLiteError) in
                reached.fire()
                release.wait()
            }
            a.value.title = "never"
            let task = Task { try await context.save() }
            await reached.next()
            task.cancel()
            release.signal()
            let error = await caught { try await task.value }
            #expect(error?.code == .interrupted)
            #expect(a.state == .dirty && a.value.title == "never")
            #expect(!context.hasIndeterminateSave)
            #expect(try await stored(database, note: "a")?.version.revision == 1)
        }
    }

    // MARK: Unknown commit outcomes

    @Test("A real unknown commit: indeterminate, saves blocked, resolved as not committed")
    func realUnknownCommit() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            context.inTransactionForTesting = { (tx) throws(SQLiteError) in
                tx.core.failNextCommitForTesting = true  // COMMIT fails after the transaction ended
            }
            a.value.title = "maybe"
            let error = await caught { try await context.save() }
            #expect(error?.code == .commitOutcomeUnknown)
            #expect(a.state == .indeterminate && context.hasIndeterminateSave)
            context.inTransactionForTesting = nil

            a.value.title = "later"               // edits are still allowed…
            #expect(await caught { try await context.save() }?.code == .misuse)  // …saves are not
            #expect(await caught { try a.discard() }?.code == .misuse)

            #expect(try await context.resolveIndeterminate() == .notCommitted)
            #expect(a.state == .dirty && a.value.title == "later" && a.baseline?.version.revision == 1)
            #expect(try await stored(database, note: "a")?.value.title == "A")
            #expect(try await context.save() == .saved(count: 1))
            #expect(try await stored(database, note: "a")?.value.title == "later")
        }
    }

    @Test("An unknown outcome that did commit: resolved exactly, later remote change conflicts")
    func unknownThatCommitted() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            let n = try context.insert(Note(id: "n", title: "new", body: nil))
            context.reportNextCommitAsUnknownForTesting = true
            a.value.title = "committed"
            #expect(await caught { try await context.save() }?.code == .commitOutcomeUnknown)
            #expect(a.state == .indeterminate && n.state == .indeterminate)
            a.value.title = "later local"

            let other = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let remote = try #require(try await other.find(Note.self, id: "a"))
            remote.value.title = "remote"
            try await other.save()

            #expect(try await context.resolveIndeterminate() == .committed)
            #expect(n.state == .clean)
            #expect(n.baseline == (try await stored(database, note: "n")))  // exact incarnation
            #expect(a.baseline?.value.title == "committed" && a.baseline?.version.revision == 2)
            #expect(a.state == .conflicted)       // the refresh found the remote change
            #expect(a.value.title == "later local")
            #expect(a.remote?.value.title == "remote" && a.remote?.version.revision == 3)
        }
    }

    @Test("A failed resolution leaves the save indeterminate")
    func failedResolution() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("closed.sqlite")), migrations: contextMigrations)
        try await database.writeRecords([.insert(Note(id: "a", title: "A", body: nil))])
        let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
        let a = try #require(try await context.find(Note.self, id: "a"))
        context.reportNextCommitAsUnknownForTesting = true
        a.value.title = "local"
        #expect(await caught { try await context.save() }?.code == .commitOutcomeUnknown)
        await database.close()
        #expect(await caught { try await context.resolveIndeterminate() }?.code == .closed)
        #expect(a.state == .indeterminate && a.value.title == "local" && context.hasIndeterminateSave)
    }

    // MARK: Change stream

    @Test("Saves are published with the context's origin; conflicts publish nothing")
    func savesArePublished() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let mine = SQLiteModelContext(store: store), theirs = SQLiteModelContext(store: store)
            let (_, changes) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            var events = changes.makeAsyncIterator()
            let a = try #require(try await mine.find(Note.self, id: "a"))
            let stale = try #require(try await theirs.find(Note.self, id: "a"))
            a.value.title = "mine"
            try await mine.save()
            stale.value.title = "stale"
            guard case .conflict = try await theirs.save() else { Issue.record("expected a conflict"); return }
            let n = try theirs.insert(Note(id: "n", title: "new", body: nil))
            try await theirs.save()

            guard case .committed(let first) = await events.next() else { Issue.record("no event"); return }
            #expect(first.sequence == 1 && first.origin == mine.origin)
            #expect(first.changes.map(\.kind) == [.updated] && first.changes[0].id(as: Note.self) == "a")
            #expect(first.changes[0].version == a.baseline?.version)
            guard case .committed(let second) = await events.next() else { Issue.record("no event"); return }
            #expect(second.sequence == 2 && second.origin == theirs.origin)  // the conflict published nothing
            #expect(second.changes[0].kind == .inserted && second.changes[0].version == n.baseline?.version)
        }
    }

    @Test("A real unknown save sends resyncRequired")
    func unknownSaveRequiresResync() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store)
            let (_, changes) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            let a = try #require(try await context.find(Note.self, id: "a"))
            context.inTransactionForTesting = { (tx) throws(SQLiteError) in tx.core.failNextCommitForTesting = true }
            a.value.title = "maybe"
            #expect(await caught { try await context.save() }?.code == .commitOutcomeUnknown)
            var events = changes.makeAsyncIterator()
            #expect(await events.next() == .resyncRequired)
            #expect(await events.next() == nil)
        }
    }

    // MARK: Markers

    @Test("Each save leaves one marker and deletes the previous one; old markers are pruned")
    func markers() async throws {
        try await withContextDatabase { database in
            let context = SQLiteModelContext(store: SQLiteModelStore(database: database))
            let a = try #require(try await context.find(Note.self, id: "a"))
            for title in ["1", "2", "3"] {
                a.value.title = title
                try await context.save()
                #expect(try await markerCount(database) == .integer(1))
            }
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO \(SQLiteModelSchema.operationsTable) VALUES (randomblob(16), 0)")
            }
            #expect(try await SQLiteModelSchema.pruneMarkers(in: database) == 1)
            #expect(try await markerCount(database) == .integer(1))
        }
    }
}

final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
