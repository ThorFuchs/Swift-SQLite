// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModels
import Testing

@Suite("G2: conditional writes, outcomes and batches")
struct WriteTests {
    let article = Article(id: "a1", title: "Hello", summary: nil, featured: true, status: .draft)
    let reading = Reading(id: 42, value: 21.5, takenAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                          count: 7, note: nil)
    let attachment = Attachment(
        id: UUID(uuidString: "6F1C2E58-0B7A-4D4E-9C55-2A1B3C4D5E6F")!, name: "scan.pdf",
        bytes: [0, 1, 2, 255], price: nil,
        owner: UUID(uuidString: "abcdef00-0000-4000-8000-00000000000a")!,
        created: SQLiteTimestamp(millisecondsSince1970: 1_700_000_000_000))

    @Test("Insert, update and delete each record type; the incarnation stays, the revision grows")
    func lifecycle() async throws {
        try await withRecordDatabase { database in
            let (a, r, t) = (article, reading, attachment)
            let inserted = try await database.write { (tx) throws(SQLiteError) in
                (try tx.insert(a), try tx.insert(r), try tx.insert(t))
            }
            let a1 = try #require(inserted.0.snapshot), r1 = try #require(inserted.1.snapshot)
            let t1 = try #require(inserted.2.snapshot)
            #expect(inserted.0 == .inserted(a1) && a1.value == a && a1.version.revision == 1)
            #expect(inserted.1 == .inserted(r1) && r1.value == r && r1.version.revision == 1)
            #expect(inserted.2 == .inserted(t1) && t1.value == t && t1.version.revision == 1)
            #expect(Set([a1.version.incarnation, r1.version.incarnation, t1.version.incarnation]).count == 3)

            var a2 = a, r2 = r, t2 = t
            a2.title = "Changed"; a2.summary = "now with summary"; a2.status = .published
            r2.value = -0.25; r2.note = "recalibrated"
            t2.price = Decimal(string: "9.99")!; t2.bytes = []
            let (aV, rV, tV) = (a1.version, r1.version, t1.version)
            let (ua, ur, ut) = (a2, r2, t2)
            let updated = try await database.write { (tx) throws(SQLiteError) in
                (try tx.update(ua, expecting: aV), try tx.update(ur, expecting: rV), try tx.update(ut, expecting: tV))
            }
            for (outcome, before) in [(updated.0.snapshot?.version, aV), (updated.1.snapshot?.version, rV),
                                      (updated.2.snapshot?.version, tV)] {
                #expect(outcome?.revision == 2)
                #expect(outcome?.incarnation == before.incarnation)
            }
            #expect(updated.0.snapshot?.value == a2)
            #expect(updated.1.snapshot?.value == r2)
            #expect(updated.2.snapshot?.value == t2)

            let read = try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Reading.self, id: 42) }
            #expect(read == updated.1.snapshot)

            let (av2, rv2, tv2) = (try #require(updated.0.snapshot).version, try #require(updated.1.snapshot).version,
                                   try #require(updated.2.snapshot).version)
            let tid = t.id
            let deleted = try await database.write { (tx) throws(SQLiteError) in
                (try tx.delete(Article.self, id: "a1", expecting: av2), try tx.delete(Reading.self, id: 42, expecting: rv2),
                 try tx.delete(Attachment.self, id: tid, expecting: tv2))
            }
            #expect(deleted.0 == .deleted && deleted.1 == .deleted && deleted.2 == .deleted)
            let remaining = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT (SELECT count(*) FROM articles) + (SELECT count(*) FROM readings) + (SELECT count(*) FROM attachments)")
            }
            #expect(remaining == .integer(0))
        }
    }

    @Test("Insert-if-absent refuses a duplicate key, even without a unique constraint")
    func duplicateInsert() async throws {
        try await withRecordDatabase { database in
            let a = article
            let other = changed(a) { $0.title = "Impostor" }
            let (first, second, count) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.insert(a), try tx.insert(other), try tx.scalar("SELECT count(*) FROM articles"))
            }
            let stored = try #require(first.snapshot)
            #expect(second == .conflict(current: stored))
            #expect(second.isApplied == false)
            #expect(count == .integer(1))
        }
    }

    @Test("Stale updates and deletes conflict with the current row; absent rows are missing")
    func staleAndMissing() async throws {
        try await withRecordDatabase { database in
            let a = article
            let v1 = try await database.write { (tx) throws(SQLiteError) in try tx.insert(a) }.snapshot!.version
            let winner = changed(a) { $0.title = "Winner" }
            let v2 = try await database.write { (tx) throws(SQLiteError) in
                try tx.update(winner, expecting: v1)
            }.snapshot!.version
            #expect(v2.revision == 2)

            let loser = changed(a) { $0.title = "Loser" }
            let (staleUpdate, staleDelete) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.update(loser, expecting: v1), try tx.delete(Article.self, id: "a1", expecting: v1))
            }
            let current = SQLiteRecordSnapshot(value: winner, version: v2)
            #expect(staleUpdate == .conflict(current: current))
            #expect(staleDelete == .conflict(current: current))

            let ghost = changed(a) { $0.id = "ghost" }
            let (missingUpdate, missingDelete, saveVersion) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.update(ghost, expecting: v1), try tx.delete(Article.self, id: "ghost", expecting: v1),
                 try tx.save(ghost, expecting: .version(v2)))
            }
            #expect(missingUpdate == .missing && missingDelete == .missing && saveVersion == .missing)
            let stored = try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a1") }
            #expect(stored == current)
        }
    }

    @Test("A key deleted and inserted again is a new record: old versions conflict (no ABA)")
    func keyReuseIsNotABA() async throws {
        try await withRecordDatabase { database in
            let r = reading
            let old = try await database.write { (tx) throws(SQLiteError) in try tx.insert(r) }.snapshot!.version
            let reborn = try await database.write { (tx) throws(SQLiteError) in
                _ = try tx.delete(Reading.self, id: 42, expecting: old)
                return try tx.insert(r)
            }
            let new = try #require(reborn.snapshot).version
            // Same key, same revision, so only the incarnation tells them apart.
            #expect(new.revision == old.revision)
            #expect(new.incarnation != old.incarnation)

            let stale = changed(r) { $0.count = 999 }
            let (update, delete) = try await database.write { (tx) throws(SQLiteError) in
                (try tx.update(stale, expecting: old), try tx.delete(Reading.self, id: 42, expecting: old))
            }
            #expect(update == .conflict(current: SQLiteRecordSnapshot(value: r, version: new)))
            #expect(delete == .conflict(current: SQLiteRecordSnapshot(value: r, version: new)))
        }
    }

    @Test("The revision never wraps at Int64.max")
    func revisionOverflow() async throws {
        try await withRecordDatabase { database in
            let a = article
            let inserted = try await database.write { (tx) throws(SQLiteError) in try tx.insert(a) }.snapshot!.version
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("UPDATE articles SET revision = ? WHERE id = 'a1'", [.integer(Int64.max - 1)])
            }
            let nearMax = try SQLiteRecordVersion(revision: Int64.max - 1, incarnation: inserted.incarnation)
            let edited = changed(a) { $0.title = "Last" }
            let atMax = try await database.write { (tx) throws(SQLiteError) in try tx.update(edited, expecting: nearMax) }
            #expect(atMax.snapshot?.version.revision == Int64.max)

            let maxVersion = try #require(atMax.snapshot).version
            let beyond = changed(edited) { $0.title = "Beyond" }
            let error = await caught {
                try await database.write { (tx) throws(SQLiteError) in try tx.update(beyond, expecting: maxVersion) }
            }
            #expect(error?.code == .invalidArgument)
            let stored = try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Article.self, id: "a1") }
            #expect(stored == atMax.snapshot)
        }
    }

    @Test("A batch commits all writes in order and reports each one")
    func batchCommits() async throws {
        try await withRecordDatabase { database in
            let (a, r, t) = (article, reading, attachment)
            let first = try await database.writeRecords([.insert(a), .insert(r)])
            guard case .committed(let reports) = first else {
                Issue.record("expected a commit, got \(first)")
                return
            }
            #expect(reports.map(\.index) == [0, 1])
            #expect(reports.map(\.table) == ["articles", "readings"])
            let a1 = try #require(reports[0].outcome(as: Article.self)?.snapshot)
            #expect(reports[0].outcome(as: Reading.self) == nil)
            #expect(reports[0].summary == .inserted(a1.version))

            let a2 = changed(a) { $0.featured = false }
            let r1 = try #require(reports[1].outcome(as: Reading.self)?.snapshot)
            let second = try await database.writeRecords([
                .update(a2, expecting: a1.version), .insert(t), .delete(Reading.self, id: 42, expecting: r1.version),
            ])
            guard case .committed(let more) = second else {
                Issue.record("expected a commit, got \(second)")
                return
            }
            #expect(more.map(\.isApplied) == [true, true, true])
            #expect(more[2].summary == .deleted)
            #expect(more[0].outcome(as: Article.self)?.snapshot?.value == a2)

            let empty = try await database.writeRecords([])
            guard case .committed(let none) = empty else {
                Issue.record("expected an empty commit")
                return
            }
            #expect(none.isEmpty)
        }
    }

    @Test("The first conflict rolls back the whole batch and names the write")
    func batchRollsBack() async throws {
        try await withRecordDatabase { database in
            let (a, r, t) = (article, reading, attachment)
            let a1 = try await database.write { (tx) throws(SQLiteError) in try tx.insert(a) }.snapshot!
            let a2 = changed(a) { $0.title = "Should not stick" }
            let outcome = try await database.writeRecords([
                .insert(r),                          // applies, then is rolled back
                .update(a2, expecting: a1.version),  // applies, then is rolled back
                .insert(a),                          // conflicts: a1 exists
                .insert(t),                          // never runs
            ])
            guard case .rolledBack(let failure) = outcome else {
                Issue.record("expected a rollback, got \(outcome)")
                return
            }
            #expect(failure.index == 2)
            #expect(failure.table == "articles")
            // The conflict shows the row as this transaction saw it, before the rollback.
            let seen = try SQLiteRecordVersion(revision: 2, incarnation: a1.version.incarnation)
            #expect(failure.summary == .conflict(current: seen))

            let state = try await database.read { (tx) throws(SQLiteError) in
                (try tx.fetch(Article.self, id: "a1"), try tx.fetch(Reading.self, id: 42),
                 try tx.scalar("SELECT count(*) FROM attachments"))
            }
            #expect(state.0 == a1)
            #expect(state.1 == nil)
            #expect(state.2 == .integer(0))

            let missing = try await database.writeRecords([
                .insert(r), .delete(Attachment.self, id: t.id, expecting: a1.version),
            ])
            guard case .rolledBack(let gone) = missing else {
                Issue.record("expected a rollback, got \(missing)")
                return
            }
            #expect(gone.index == 1 && gone.summary == .missing)
            let readings = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM readings") }
            #expect(readings == .integer(0))
        }
    }

    @Test("Errors stay errors: a constraint violation throws and rolls back the batch")
    func errorsAreNotOutcomes() async throws {
        try await withRecordDatabase { database in
            try await database.write { (tx) throws(SQLiteError) in
                try tx.executeScript("CREATE UNIQUE INDEX articles_title ON articles(title)")
            }
            let a = article
            let twin = changed(a) { $0.id = "a2" }  // a different key with the same title
            let r = reading
            let error = await caught { try await database.writeRecords([.insert(r), .insert(a), .insert(twin)]) }
            #expect(error?.code == .constraint)
            let counts = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT (SELECT count(*) FROM articles) + (SELECT count(*) FROM readings)")
            }
            #expect(counts == .integer(0))

            let readOnly = await caught {
                try await database.read { (tx) throws(SQLiteError) in try tx.insert(a) }
            }
            #expect(readOnly?.code == .readOnly)
        }
    }

    @Test("Two databases on one file: exactly one of two racing writers wins", arguments: 0..<10)
    func racingWriters(round: Int) async throws {
        try await withTwoRecordDatabases { left, right in
            let a = article
            // Insert vs insert.
            async let l1 = left.write { (tx) throws(SQLiteError) in try tx.insert(a) }
            async let r1 = right.write { (tx) throws(SQLiteError) in try tx.insert(a) }
            let inserts = try await [l1, r1]
            #expect(inserts.filter(\.isApplied).count == 1)
            let winner = try #require(inserts.first(where: \.isApplied)?.snapshot)
            #expect(inserts.contains(.conflict(current: winner)))

            // Update vs update from the same version.
            let x = changed(a) { $0.title = "left" }, y = changed(a) { $0.title = "right" }
            let base = winner.version
            async let l2 = left.write { (tx) throws(SQLiteError) in try tx.update(x, expecting: base) }
            async let r2 = right.write { (tx) throws(SQLiteError) in try tx.update(y, expecting: base) }
            let updates = try await [l2, r2]
            #expect(updates.filter(\.isApplied).count == 1)
            let updated = try #require(updates.first(where: \.isApplied)?.snapshot)
            #expect(updated.version.revision == 2)
            #expect(updates.contains(.conflict(current: updated)))

            // Delete vs update from the same version.
            let z = changed(a) { $0.title = "survivor?" }
            let current = updated.version
            async let l3 = left.write { (tx) throws(SQLiteError) in try tx.delete(Article.self, id: "a1", expecting: current) }
            async let r3 = right.write { (tx) throws(SQLiteError) in try tx.update(z, expecting: current) }
            let (deleteOutcome, updateOutcome) = try await (l3, r3)
            #expect(deleteOutcome.isApplied != updateOutcome.isApplied)
            if deleteOutcome.isApplied {
                #expect(updateOutcome == .missing)
            } else {
                let survivor = try #require(updateOutcome.snapshot)
                #expect(deleteOutcome == .conflict(current: survivor))
            }
        }
    }
}
