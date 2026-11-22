// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import SQLiteSwift
@testable import SQLiteSwiftModelContext
import SQLiteSwiftModels
import Testing

/// `Observations` (SE-0475) turns observable state into an async sequence, outside
/// SwiftUI. These tests show that handles and live queries work with it.
@MainActor
@Suite("1.2: Observations with handles and live queries")
struct ObservationsTests {
    @Test("A handle's value, local edits and remote updates arrive through Observations")
    func handleValues() async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store), other = SQLiteModelContext(store: store)
            let note = try #require(try await context.find(Note.self, id: "a"))
            var titles = Observations { note.value.title }.makeAsyncIterator()
            #expect(await titles.next() == "A")

            note.value.title = "local edit"
            #expect(await titles.next() == "local edit")
            try note.discard()
            #expect(await titles.next() == "A")

            let remote = try #require(try await other.find(Note.self, id: "a"))
            remote.value.title = "remote"
            try await other.save()
            try await context.refresh(note)           // a clean handle takes the stored row
            #expect(await titles.next() == "remote")
            #expect(note.state == .clean)
        }
    }

    @Test("A live query's results arrive through Observations")
    func liveQueryResults() async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        try await withContextDatabase { database in
            let store = SQLiteModelStore(database: database)
            let context = SQLiteModelContext(store: store)
            let notes = context.liveQuery(Note.self)
            let running = Task { try await notes.run() }
            defer { running.cancel() }
            await notes.waitForTesting { notes.isLoaded }

            var counts = Observations { notes.results.count }.makeAsyncIterator()
            #expect(await counts.next() == 2)
            _ = try context.insert(Note(id: "c", title: "C", body: nil))
            try await context.save()
            #expect(await counts.next() == 3)
        }
    }
}
