// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
@testable import SQLiteSwift
@testable import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

@Suite("G4: committed-change stream")
struct ChangeStreamTests {
    let article = Article(id: "a1", title: "Hello", summary: nil, featured: true, status: .draft)
    let reading = Reading(id: 7, value: 1, takenAt: Date(timeIntervalSince1970: 1_700_000_000), count: 0, note: nil)

    private func withStore<T>(_ body: (SQLiteModelStore) async throws -> T) async throws -> T {
        try await withRecordDatabase { database in try await body(SQLiteModelStore(database: database)) }
    }

    @Test("A committed batch is published with its sequence, origin, identities, kinds and versions")
    func publishesCommittedBatches() async throws {
        try await withStore { store in
            let (empty, changes) = try await store.subscribe { (tx) throws(SQLiteError) in
                try tx.fetchAll(Article.self)
            }
            #expect(empty.isEmpty)
            var events = changes.makeAsyncIterator()
            let origin = SQLiteChangeOrigin()
            let a = article, r = reading

            let first = try await store.writeRecords([.insert(a), .insert(r)], origin: origin)
            guard case .committed(let reports) = first else { Issue.record("got \(first)"); return }
            let e1 = try #require(await events.next())
            guard case .committed(let c1) = e1 else { Issue.record("got \(e1)"); return }
            #expect(c1.sequence == 1 && c1.origin == origin)
            #expect(c1.changes.map(\.kind) == [.inserted, .inserted])
            #expect(c1.changes.map(\.table) == ["articles", "readings"])
            #expect(c1.changes[0].id(as: Article.self) == "a1")
            #expect(c1.changes[0].id(as: Reading.self) == nil)
            #expect(c1.changes[1].id(as: Reading.self) == 7)
            #expect(c1.changes[0].version == reports[0].outcome(as: Article.self)?.snapshot?.version)

            let v1 = try #require(reports[0].outcome(as: Article.self)?.snapshot?.version)
            let edited = changed(a) { $0.title = "Edited" }
            try await store.writeRecords([.update(edited, expecting: v1)])
            let e2 = try #require(await events.next())
            guard case .committed(let c2) = e2 else { Issue.record("got \(e2)"); return }
            #expect(c2.sequence == 2 && c2.origin == nil)
            #expect(c2.changes.first?.kind == .updated && c2.changes.first?.version?.revision == 2)

            let v2 = try #require(c2.changes.first?.version)
            try await store.writeRecords([.delete(Article.self, id: "a1", expecting: v2)])
            let e3 = try #require(await events.next())
            guard case .committed(let c3) = e3 else { Issue.record("got \(e3)"); return }
            #expect(c3.sequence == 3 && c3.changes.first?.kind == .deleted && c3.changes.first?.version == nil)
            #expect(try await store.currentSequence() == 3)
        }
    }

    @Test("Rolled-back batches, failed writes and unmanaged writes publish nothing")
    func nothingForRollbackOrError() async throws {
        try await withStore { store in
            let a = article, r = reading
            try await store.writeRecords([.insert(a)])              // sequence 1, before subscribing
            let (_, changes) = try await store.subscribe { (tx) throws(SQLiteError) in try tx.fetchAll(Article.self) }
            var events = changes.makeAsyncIterator()

            let conflict = try await store.writeRecords([.insert(r), .insert(a)])
            guard case .rolledBack = conflict else { Issue.record("got \(conflict)"); return }
            try await store.database.write { (tx) throws(SQLiteError) in
                try tx.executeScript("CREATE UNIQUE INDEX readings_count ON readings(count)")
            }
            let twin = changed(r) { $0.id = 8 }
            let failure = await caught { try await store.writeRecords([.insert(r), .insert(twin)]) }
            #expect(failure?.code == .constraint)
            try await store.database.writeRecords([.insert(changed(a) { $0.id = "raw" })])  // not through the store

            try await store.writeRecords([.insert(r)])
            let next = try #require(await events.next())
            guard case .committed(let change) = next else { Issue.record("got \(next)"); return }
            #expect(change.sequence == 2)                           // nothing in between
            #expect(change.changes.map(\.table) == ["readings"])
        }
    }

    @Test("A commit with an unknown outcome publishes nothing and asks every subscriber to resync")
    func unknownOutcomeRequiresResync() async throws {
        try await withStore { store in
            let (_, first) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            let (_, second) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            let r = reading
            let error = await caught {
                try await store.managedWrite(origin: nil) { (tx) throws(SQLiteError) in
                    let report = try SQLiteRecordWrite.insert(r).run(at: 0, in: tx)
                    tx.core.failNextCommitForTesting = true
                    return .commit(((), [report]))
                }
            }
            #expect(error?.code == .commitOutcomeUnknown)
            for subscription in [first, second] {
                var events = subscription.makeAsyncIterator()
                #expect(await events.next() == .resyncRequired)
                #expect(await events.next() == nil)                // and it ends
            }
            #expect(store.hub.subscriberCount == 0)
        }
    }

    @Test("Watermark: a batch committed before the snapshot is read is in the snapshot, not the stream")
    func batchBeforeSnapshotIsDropped() async throws {
        try await withStore { store in
            let reached = Signal()
            let release = DispatchSemaphore(value: 0)
            let r = reading
            let subscribing = Task {
                try await store.subscribe { (tx) throws(SQLiteError) in
                    reached.fire()
                    release.wait()                                 // nothing read yet: no snapshot taken
                    return try tx.fetchAll(Reading.self).count
                }
            }
            await reached.next()                                    // registered, snapshot pending
            try await store.writeRecords([.insert(r)])              // sequence 1, buffered
            release.signal()
            let (count, changes) = try await subscribing.value
            #expect(count == 1)                                     // the snapshot has it…
            try await store.writeRecords([.insert(changed(r) { $0.id = 8 })])
            var events = changes.makeAsyncIterator()
            let next = try #require(await events.next())
            guard case .committed(let change) = next else { Issue.record("got \(next)"); return }
            #expect(change.sequence == 2)                           // …so the stream starts after it
        }
    }

    @Test("Watermark: a batch committed after the snapshot was taken is delivered")
    func batchAfterSnapshotIsDelivered() async throws {
        try await withStore { store in
            let reached = Signal()
            let release = DispatchSemaphore(value: 0)
            let r = reading
            let subscribing = Task {
                try await store.subscribe { (tx) throws(SQLiteError) in
                    let count = try tx.fetchAll(Reading.self).count  // the snapshot is taken here
                    reached.fire()
                    release.wait()
                    return count
                }
            }
            await reached.next()
            try await store.writeRecords([.insert(r)])              // sequence 1, after the snapshot
            release.signal()
            let (count, changes) = try await subscribing.value
            #expect(count == 0)                                     // not in the snapshot…
            var events = changes.makeAsyncIterator()
            let next = try #require(await events.next())
            guard case .committed(let change) = next else { Issue.record("got \(next)"); return }
            #expect(change.sequence == 1)                           // …so it is in the stream
        }
    }

    @Test("Subscribers joining during concurrent writes see every revision exactly once", arguments: 0..<5)
    func concurrentSubscribe(round: Int) async throws {
        try await withStore { store in
            let r = reading
            let inserted = try await store.writeRecords([.insert(r)])
            guard case .committed(let reports) = inserted else { Issue.record("got \(inserted)"); return }
            var version = try #require(reports[0].outcome(as: Reading.self)?.snapshot?.version)
            let updates = 40

            let writer = Task {
                for step in 1...updates {
                    let next = changed(r) { $0.count = step }
                    let outcome = try await store.writeRecords([.update(next, expecting: version)])
                    guard case .committed(let reports) = outcome,
                          let stored = reports[0].outcome(as: Reading.self)?.snapshot
                    else { Issue.record("update \(step) did not commit"); return }
                    version = stored.version
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for subscriber in 0..<8 {
                    group.addTask {
                        for _ in 0..<subscriber { await Task.yield() }
                        let (start, changes) = try await store.subscribe { (tx) throws(SQLiteError) in
                            try tx.fetch(Reading.self, id: 7)?.version.revision ?? 0
                        }
                        var expected = start + 1
                        for await event in changes {
                            guard case .committed(let change) = event else {
                                Issue.record("subscriber \(subscriber): unexpected \(event)")
                                return
                            }
                            #expect(change.changes.first?.version?.revision == expected)
                            expected += 1
                            if expected > Int64(updates) + 1 { return }
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await writer.value
        }
    }

    @Test("Concurrent writers are published in commit order")
    func publishedInOrder() async throws {
        try await withStore { store in
            let (_, changes) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in 1...20 {
                    group.addTask {
                        try await store.writeRecords([.insert(Reading(
                            id: Int64(id), value: 0, takenAt: Date(timeIntervalSince1970: 0), count: id, note: nil))])
                    }
                }
                try await group.waitForAll()
            }
            var events = changes.makeAsyncIterator()
            for sequence in 1...20 {
                guard case .committed(let change) = await events.next() else {
                    Issue.record("missing event \(sequence)")
                    return
                }
                #expect(change.sequence == Int64(sequence))
            }
        }
    }

    @Test("A full buffer is replaced by resyncRequired; nothing grows without bound")
    func overflowRequiresResync() async throws {
        try await withStore { store in
            let (_, changes) = try await store.subscribe(bufferSize: 2) { (_) throws(SQLiteError) in 0 }
            for id in 1...3 {
                try await store.writeRecords([.insert(changed(reading) { $0.id = Int64(id) })])
            }
            var events = changes.makeAsyncIterator()
            #expect(await events.next() == .resyncRequired)
            #expect(await events.next() == nil)
            #expect(store.hub.subscriberCount == 0)
            #expect(await caught { try await store.subscribe(bufferSize: 0) { (_) throws(SQLiteError) in 0 } }?.code == .invalidArgument)
        }
    }

    @Test("Cancelling the consumer, cancelling the subscription or dropping it cleans up")
    func cleanupOnCancel() async throws {
        try await withStore { store in
            let (_, waiting) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            let consumer = Task { () -> Int in
                var count = 0
                for await _ in waiting { count += 1 }
                return count
            }
            consumer.cancel()
            #expect(await consumer.value == 0)
            #expect(store.hub.subscriberCount == 0)

            let (_, explicit) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
            explicit.cancel()
            var iterator = explicit.makeAsyncIterator()
            #expect(await iterator.next() == nil)

            do {
                let held = try await store.subscribe { (_) throws(SQLiteError) in 0 }
                #expect(store.hub.subscriberCount == 1)
                withExtendedLifetime(held.changes) {}
            }
            #expect(store.hub.subscriberCount == 0)             // released with the subscription
        }
    }

    @Test("Closing the store ends every subscription and refuses new ones")
    func closeEndsSubscriptions() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("close.sqlite")), migrations: recordMigrations)
        let store = SQLiteModelStore(database: database)
        let (_, changes) = try await store.subscribe { (_) throws(SQLiteError) in 0 }
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in changes { count += 1 }
            return count
        }
        await store.close()
        #expect(await consumer.value == 0)
        #expect(await caught { try await store.subscribe { (_) throws(SQLiteError) in 0 } }?.code == .closed)
    }
}
