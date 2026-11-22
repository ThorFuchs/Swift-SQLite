// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
@testable import SQLiteSwiftModels
import SQLiteSwiftTesting
import Testing

@Suite("1.2: async live records (no main actor)")
struct LiveRecordsTests {
    let article = Article(id: "a1", title: "Hello", summary: nil, featured: true, status: .draft)
    let reading = Reading(id: 1, value: 1, takenAt: Date(timeIntervalSince1970: 1_700_000_000), count: 0, note: nil)

    @Test("The current result first, then each real change: insert, update, delete")
    func followsChanges() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database)
            var live = store.records(Article.self).makeAsyncIterator()
            #expect(try await live.next()?.isEmpty == true)

            let a = article
            guard case .committed(let r1) = try await store.writeRecords([.insert(a)]) else { Issue.record("insert"); return }
            #expect(try await live.next()?.map(\.value) == [a])

            let v1 = try #require(r1[0].outcome(as: Article.self)?.snapshot).version
            let b = changed(a) { $0.title = "B" }
            try await store.writeRecords([.update(b, expecting: v1)])
            let afterUpdate = try #require(try await live.next())
            #expect(afterUpdate.map(\.value) == [b] && afterUpdate[0].version.revision == 2)

            try await store.writeRecords([.delete(Article.self, id: "a1", expecting: afterUpdate[0].version)])
            #expect(try await live.next()?.isEmpty == true)
        }
    }

    @Test("A filter applies; other tables and changes outside the filter emit nothing")
    func filterAndUnrelated() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database)
            var drafts = store.records(Article.self, where: .equals("status", .text("draft"))).makeAsyncIterator()
            #expect(try await drafts.next()?.isEmpty == true)
            try await store.writeRecords([.insert(reading)])                                          // other table
            try await store.writeRecords([.insert(changed(article) { $0.id = "p"; $0.status = .published })])  // outside filter
            try await store.writeRecords([.insert(article)])                                          // a draft
            #expect(try await drafts.next()?.map(\.value.id) == ["a1"])                               // nothing in between
        }
    }

    @Test("A burst while the consumer is busy becomes one read")
    func coalesces() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database)
            var live = store.records(Reading.self).makeAsyncIterator()
            #expect(try await live.next()?.isEmpty == true)
            for id in 1...20 { try await store.writeRecords([.insert(changed(reading) { $0.id = Int64(id) })]) }
            #expect(try await live.next()?.count == 20)                    // all twenty at once
            try await store.writeRecords([.insert(changed(reading) { $0.id = 21 })])
            #expect(try await live.next()?.count == 21)                    // no stale intermediate results
        }
    }

    @Test("A full buffer leads to a fresh read, then live again")
    func overflowRereads() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database)
            var live = store.records(Reading.self, bufferSize: 2).makeAsyncIterator()
            #expect(try await live.next()?.isEmpty == true)
            for id in 1...10 { try await store.writeRecords([.insert(changed(reading) { $0.id = Int64(id) })]) }
            #expect(try await live.next()?.count == 10)
            try await store.writeRecords([.insert(changed(reading) { $0.id = 11 })])
            #expect(try await live.next()?.count == 11)
        }
    }

    @Test("Results are never truncated: too many rows throw")
    func limits() async throws {
        try await withRecordDatabase { database in
            let store = SQLiteModelStore(database: database)
            try await store.writeRecords([.insert(reading), .insert(changed(reading) { $0.id = 2 })])
            var live = store.records(Reading.self, limits: SQLiteQueryLimits(maxRows: 1)).makeAsyncIterator()
            let error = await caught { try await live.next() }
            #expect(error?.code == .rowLimitExceeded)
        }
    }

    @Test("It ends when the consumer is cancelled or the store closes")
    func endsCleanly() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(
            SQLiteConfiguration(path: directory.file("live.sqlite")), migrations: recordMigrations)
        let store = SQLiteModelStore(database: database)

        let first = Signal()
        let consumer = Task { () -> Int in
            var seen = 0
            for try await _ in store.records(Reading.self) {
                seen += 1
                first.fire()
            }
            return seen
        }
        await first.next()
        consumer.cancel()
        #expect(try await consumer.value == 1)
        #expect(store.hub.subscriberCount == 0)

        var live = store.records(Reading.self).makeAsyncIterator()
        _ = try await live.next()
        await store.close()
        #expect(try await live.next() == nil)
    }
}
