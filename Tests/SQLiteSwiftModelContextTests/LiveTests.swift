// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
@testable import SQLiteSwiftModelContext
@testable import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

@MainActor
@Suite("G5: live handles and live queries")
struct LiveTests {
    /// Starts `context.observeChanges()` and waits until it is subscribed.
    private func observing(_ context: SQLiteModelContext) async -> Task<Void, any Error> {
        let task = Task { try await context.observeChanges() }
        await context.waitForObservationForTesting { context.store.hub.subscriberCount > 0 }
        return task
    }

    @Test("Two contexts: a clean handle takes the other context's save")
    func cleanHandleUpdates() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let viewer = SQLiteModelContext(store: store), editor = SQLiteModelContext(store: store)
            let shown = try #require(try await viewer.find(Note.self, id: "a"))
            let observation = await observing(viewer)
            defer { observation.cancel() }

            let edited = try #require(try await editor.find(Note.self, id: "a"))
            edited.value.title = "from the editor"
            try await editor.save()
            let sequence = try await store.currentSequence()
            await viewer.waitForObservationForTesting { viewer.lastAppliedSequence >= sequence }

            #expect(shown.value.title == "from the editor")
            #expect(shown.state == .clean && !shown.hasUnsavedChanges)
            #expect(shown.baseline == edited.baseline)
        }
    }

    @Test("Two contexts: a dirty handle keeps its draft and shows the conflict")
    func dirtyHandleKeepsDraft() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let mine = SQLiteModelContext(store: store), theirs = SQLiteModelContext(store: store)
            let draft = try #require(try await mine.find(Note.self, id: "a"))
            let observation = await observing(mine)
            defer { observation.cancel() }
            draft.value.body = "my draft"

            let remote = try #require(try await theirs.find(Note.self, id: "a"))
            remote.value.title = "theirs"
            try await theirs.save()
            let sequence = try await store.currentSequence()
            await mine.waitForObservationForTesting { mine.lastAppliedSequence >= sequence }

            #expect(draft.value.body == "my draft" && draft.value.title == "A")
            #expect(draft.state == .conflicted)
            #expect(draft.remote?.value.title == "theirs" && draft.baseline?.version.revision == 1)
            try draft.keepLocal()
            #expect(try await mine.save() == .saved(count: 1))
            // keepLocal keeps the whole local value; there is no automatic field merge.
            #expect(try await stored(database, note: "a")?.value == Note(id: "a", title: "A", body: "my draft"))
        }
    }

    @Test("Two contexts: a remote deletion is shown, never undone")
    func remoteDeletionIsShown() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let mine = SQLiteModelContext(store: store), theirs = SQLiteModelContext(store: store)
            let clean = try #require(try await mine.find(Note.self, id: "a"))
            let dirty = try #require(try await mine.find(Note.self, id: "b"))
            let observation = await observing(mine)
            defer { observation.cancel() }
            dirty.value.title = "editing b"

            try theirs.delete(try #require(try await theirs.find(Note.self, id: "a")))
            try theirs.delete(try #require(try await theirs.find(Note.self, id: "b")))
            try await theirs.save()
            let sequence = try await store.currentSequence()
            await mine.waitForObservationForTesting { mine.lastAppliedSequence >= sequence }

            #expect(clean.state == .deleted && clean.isDeletedRemotely && !mine.contains(Note.self, id: "a"))
            #expect(dirty.state == .conflicted && dirty.isDeletedRemotely && dirty.value.title == "editing b")
            #expect(try await mine.save() == .saved(count: 0))  // nothing resurrected
            #expect(try await stored(database, note: "b") == nil)
        }
    }

    @Test("Own saves aren't read back, and a handle being saved is left alone")
    func ownSavesAndSavingHandles() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store), other = SQLiteModelContext(store: store)
            let a = try #require(try await context.find(Note.self, id: "a"))
            let observation = await observing(context)
            defer { observation.cancel() }

            a.value.title = "mine"
            try await context.save()
            let sequence = try await store.currentSequence()
            await context.waitForObservationForTesting { context.lastAppliedSequence >= sequence }
            #expect(a.state == .clean && a.baseline?.version.revision == 2)

            // Another context changes the row while this one's save is suspended.
            let reached = Gate(), release = Gate()
            context.beforeWriteForTesting = { reached.open(); await release.wait() }
            a.value.title = "mine again"
            let save = Task { try await context.save() }
            await reached.wait()
            let remote = try #require(try await other.find(Note.self, id: "a"))
            remote.value.body = "theirs"
            try await other.save()
            let remoteSequence = try await store.currentSequence()
            await context.waitForObservationForTesting { context.lastAppliedSequence >= remoteSequence }
            #expect(a.state == .saving && a.value.title == "mine again")  // not overwritten mid-save
            release.open()
            guard case .conflict = try await save.value else { Issue.record("expected a conflict"); return }
            #expect(a.state == .conflicted && a.remote?.value.body == "theirs")
        }
    }

    @Test("After a resync every handle is read again and observation goes on")
    func resyncRereadsEverything() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let viewer = SQLiteModelContext(store: store), writer = SQLiteModelContext(store: store)
            let shown = try #require(try await viewer.find(Note.self, id: "a"))
            let observation = await observing(viewer)
            defer { observation.cancel() }

            // A write behind the store's back: no event, so the viewer doesn't see it…
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("UPDATE notes SET body = 'raw', revision = revision + 1 WHERE id = 'a'")
            }
            #expect(shown.value.body == nil)

            // …until a write the stream can't confirm (an unknown commit) forces a resync.
            let w = try #require(try await writer.find(Note.self, id: "a"))
            writer.inTransactionForTesting = { (tx) throws(SQLiteError) in tx.core.failNextCommitForTesting = true }
            w.value.title = "unknown"
            #expect(await caught { try await writer.save() }?.code == .commitOutcomeUnknown)
            await viewer.waitForObservationForTesting { viewer.resyncCount == 1 && shown.value.body == "raw" }
            #expect(shown.state == .clean && shown.baseline?.version.revision == 2)

            writer.inTransactionForTesting = nil
            #expect(try await writer.resolveIndeterminate() == .notCommitted)
            try writer.forget(w)
            let b = try #require(try await writer.find(Note.self, id: "b"))
            b.value.title = "seen"
            try await writer.save()
            let sequence = try await store.currentSequence()
            await viewer.waitForObservationForTesting { viewer.lastAppliedSequence >= sequence }
            let shownB = try #require(try await viewer.find(Note.self, id: "b"))
            #expect(shownB.value.title == "seen")
        }
    }

    @Test("Cancelling observation ends its subscription")
    func cancellingObservationCleansUp() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store)
            let observation = await observing(context)
            #expect(store.hub.subscriberCount == 1)
            observation.cancel()
            try await observation.value
            #expect(store.hub.subscriberCount == 0)
        }
    }

    // MARK: Live queries

    @Test("A live query follows inserts, updates and deletes of its table only")
    func liveQueryFollowsItsTable() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store)
            let notes = context.liveQuery(Note.self)
            let running = Task { try await notes.run() }
            defer { running.cancel() }
            await notes.waitForTesting { notes.isLoaded }
            #expect(notes.results.map(\.value.id) == ["a", "b"])

            _ = try context.insert(Note(id: "c", title: "C", body: nil))
            try await context.save()
            await notes.waitForTesting { notes.results.count == 3 }
            #expect(notes.results.map(\.value.id) == ["a", "b", "c"])

            let b = try #require(try await context.find(Note.self, id: "b"))
            try context.delete(b)
            try await context.save()
            await notes.waitForTesting { notes.results.map(\.value.id) == ["a", "c"] }

            let reads = notes.readCount
            let counter = try #require(try await context.find(Counter.self, id: 1))
            counter.value.count = 9
            try await context.save()                              // another table
            let a = try #require(try await context.find(Note.self, id: "a"))
            a.value.title = "A2"
            try await context.save()
            await notes.waitForTesting { notes.results.first?.value.title == "A2" }
            #expect(notes.readCount == reads + 1)                // the counter batch caused no read
        }
    }

    @Test("A filtered live query; it ends with its task")
    func filteredLiveQuery() async throws {
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store)
            let starred = SQLiteLiveQuery(Note.self, where: .equals("body", .text("*")), store: store)
            let running = Task { try await starred.run() }
            await starred.waitForTesting { starred.isLoaded }
            #expect(starred.results.isEmpty)

            let a = try #require(try await context.find(Note.self, id: "a"))
            a.value.body = "*"
            try await context.save()
            await starred.waitForTesting { starred.results.count == 1 }
            #expect(starred.results.first?.value.id == "a" && starred.results.first?.version.revision == 2)

            running.cancel()
            try await running.value
            #expect(store.hub.subscriberCount == 0)
        }
    }
}
