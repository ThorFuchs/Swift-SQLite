// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
@testable import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

@Suite("1.2: resumable change stream")
struct ResumableStreamTests {
    let article = Article(id: "a1", title: "Hello", summary: nil, featured: true, status: .draft)
    let reading = Reading(id: 7, value: 1, takenAt: Date(timeIntervalSince1970: 1_700_000_000), count: 0, note: nil)
    let attachment = Attachment(
        id: UUID(uuidString: "6F1C2E58-0B7A-4D4E-9C55-2A1B3C4D5E6F")!, name: "scan.pdf", bytes: [1, 2], price: nil,
        owner: UUID(uuidString: "abcdef00-0000-4000-8000-00000000000a")!,
        created: SQLiteTimestamp(millisecondsSince1970: 1_700_000_000_000))

    private func open(_ path: String) async throws -> SQLiteDatabase {
        try await SQLiteDatabase.open(SQLiteConfiguration(path: path), migrations: recordMigrations)
    }

    private func next(_ events: inout SQLiteChangeSubscription.Iterator) async throws -> SQLiteCommittedChange {
        let event = await events.next()
        guard case .committed(let change) = event else {
            Issue.record("expected a committed batch, got \(String(describing: event))")
            throw SQLiteError.misuse("no batch")
        }
        return change
    }

    @Test("After a restart a consumer continues exactly after its last sequence, then live")
    func resumesAfterRestart() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let path = directory.file("resume.sqlite")
        let origin = SQLiteChangeOrigin()
        let (a, r, t) = (article, reading, attachment)

        let first = try await open(path)
        let store = SQLiteModelStore(database: first, changeLog: .retain())
        try await store.writeRecords([.insert(a)], origin: origin)                 // 1
        try await store.writeRecords([.insert(r), .insert(t)])                     // 2
        let v1 = try await first.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a1") }!.version
        try await store.writeRecords([.update(changed(a) { $0.title = "B" }, expecting: v1)])  // 3
        _ = try await store.writeRecords([.insert(a)])                             // conflict: rolled back, not logged
        await store.close()

        let second = try await open(path)
        let resumed = SQLiteModelStore(database: second, changeLog: .retain())
        let subscription = try await resumed.subscribe(after: 1)
        var events = subscription.makeAsyncIterator()
        let two = try await next(&events)
        #expect(two.sequence == 2 && two.origin == nil)
        #expect(two.changes.map(\.kind) == [.inserted, .inserted])
        #expect(two.changes[0].id(as: Reading.self) == 7)                          // integer key, exact
        #expect(two.changes[1].id(as: Attachment.self) == t.id)                    // 16-byte BLOB key, exact
        let three = try await next(&events)
        #expect(three.sequence == 3 && three.changes.first?.kind == .updated)
        #expect(three.changes.first?.id(as: Article.self) == "a1")                 // text key, exact
        #expect(three.changes.first?.version?.revision == 2 && three.changes.first?.version?.incarnation == v1.incarnation)

        try await resumed.writeRecords([.delete(Reading.self, id: 7, expecting: two.changes[0].version!)], origin: origin)
        let live = try await next(&events)
        #expect(live.sequence == 4 && live.origin == origin && live.changes.first?.kind == .deleted)

        let fromStart = try await resumed.subscribe(after: 0)
        var all = fromStart.makeAsyncIterator()
        let one = try await next(&all)
        #expect(one.sequence == 1 && one.origin == origin)                         // origins survive the restart
        await resumed.close()
    }

    @Test("Up to date: only live batches")
    func upToDate() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database, changeLog: .retain())
            try await store.writeRecords([.insert(article)])
            let subscription = try await store.subscribe(after: 1)
            try await store.writeRecords([.insert(reading)])
            var events = subscription.makeAsyncIterator()
            #expect(try await next(&events).sequence == 2)
        }
    }

    @Test("Beyond retention, ahead of the store, or too much to buffer: resyncRequired")
    func cannotContinue() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database, changeLog: .retain(batches: 3))
            for id in 1...6 {
                try await store.writeRecords([.insert(changed(reading) { $0.id = Int64(id) })])
            }
            let kept = try await database.read { (tx) throws(SQLiteError) in
                (try tx.scalar("SELECT count(*) FROM \(SQLiteModelSchema.changeBatchesTable)"),
                 try tx.scalar("SELECT min(sequence) FROM \(SQLiteModelSchema.changeBatchesTable)"))
            }
            #expect(kept.0 == .integer(3) && kept.1 == .integer(4))

            for (after, buffer) in [(Int64(2), 1024), (Int64(9), 1024), (Int64(3), 2)] {
                var events = try await store.subscribe(after: after, bufferSize: buffer).makeAsyncIterator()
                #expect(await events.next() == .resyncRequired, "after \(after), buffer \(buffer)")
                #expect(await events.next() == nil)
            }
            var events = try await store.subscribe(after: 3).makeAsyncIterator()   // the oldest that still fits
            #expect(try await next(&events).sequence == 4)
            #expect(try await next(&events).sequence == 5)
            #expect(try await next(&events).sequence == 6)
        }
    }

    @Test("Without a change log, resuming is refused; arguments are checked")
    func configuration() async throws {
        try await withRecordDatabase { database in
            let plain = SQLiteModelStore(database: database)
            #expect(await caught { try await plain.subscribe(after: 0) }?.code == .invalidConfiguration)
            let logged = SQLiteModelStore(database: database, changeLog: .retain())
            #expect(await caught { try await logged.subscribe(after: -1) }?.code == .invalidArgument)
            #expect(await caught { try await logged.subscribe(after: 0, bufferSize: 0) }?.code == .invalidArgument)
            let broken = SQLiteModelStore(database: database, changeLog: .retain(batches: 0))
            #expect(await caught { try await broken.writeRecords([.insert(article)]) }?.code == .invalidConfiguration)
        }
    }

    @Test("Resuming while writes continue delivers every batch exactly once, in order", arguments: 0..<5)
    func resumeDuringWrites(round: Int) async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database, changeLog: .retain())
            let base = reading
            for id in 1...10 { try await store.writeRecords([.insert(changed(base) { $0.id = Int64(id) })]) }
            let total = 60
            let writer = Task {
                for id in 11...total { try await store.writeRecords([.insert(changed(base) { $0.id = Int64(id) })]) }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for start in [Int64(0), 3, 7, 10] {
                    group.addTask {
                        for _ in 0..<Int(start) { await Task.yield() }
                        var expected = start + 1
                        for await event in try await store.subscribe(after: start) {
                            guard case .committed(let change) = event else {
                                Issue.record("after \(start): unexpected \(event)")
                                return
                            }
                            #expect(change.sequence == expected)
                            expected += 1
                            if expected > Int64(total) { return }
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await writer.value
        }
    }
}
