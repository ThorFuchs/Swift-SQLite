// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
import SQLiteSwiftTesting
import Testing

/// Records what it sees, and which task-local trace ID was current at start and finish.
final class RecordingObserver: SQLiteObserver {
    @TaskLocal static var traceID: String?

    struct Entry: Sendable {
        let kind: SQLiteOperation.Kind
        let outcome: String
        let startTrace: String?
        let finishTrace: String?
        let wait: Duration
        let duration: Duration
    }

    private let entries = SQLiteLocked([Entry]())
    var all: [Entry] { entries.withLock { $0 } }

    func operationWillStart(_ operation: SQLiteOperation) -> String? { Self.traceID }

    func operationDidFinish(_ report: SQLiteOperationReport, context: String?) {
        let outcome = switch report.outcome {
        case .succeeded: "succeeded"
        case .rolledBack: "rolledBack"
        case .failed(let error): "failed:\(error.code)"
        }
        let entry = Entry(kind: report.operation.kind, outcome: outcome, startTrace: context,
                          finishTrace: Self.traceID, wait: report.connectionWait, duration: report.duration)
        entries.withLock { $0.append(entry) }
    }
}

@Suite("Observation hooks and fault injection")
struct ObservationTests {
    @Test("Every operation is reported once, with its kind and outcome")
    func reportsOperations() async throws {
        let observer = RecordingObserver()
        try await withDatabase(configure: { $0.observer = observer }) { database, directory in
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            _ = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            try await database.writeOrRollback { (tx) throws(SQLiteError) -> SQLiteTransactionOutcome<Void> in
                try tx.execute("INSERT INTO items (name) VALUES ('b')")
                return .rollback(())
            }
            _ = await caught {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            }
            _ = try await database.checkpoint()
            _ = try await database.quickCheck()
            try await database.optimize()
            try await database.backup(to: directory.file("b.sqlite"))
            try await database.vacuum(into: directory.file("v.sqlite"))
            _ = try await database.resolveCommit { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT 1 FROM items WHERE name = 'a'") != nil
            }
        }
        let seen = observer.all.map { "\($0.kind):\($0.outcome)" }
        #expect(seen == [
            "write:succeeded", "read:succeeded", "write:rolledBack", "write:failed:constraint",
            "checkpoint:succeeded", "quick_check:succeeded", "optimize:succeeded",
            "backup:succeeded", "vacuum_into:succeeded", "resolve_commit:succeeded",
        ])
        #expect(observer.all.allSatisfy { $0.wait <= $0.duration })
    }

    @Test("Both callbacks run on the caller's task, so task-local context is there")
    func taskLocalContext() async throws {
        let observer = RecordingObserver()
        try await withDatabase(configure: { $0.observer = observer }) { database, _ in
            try await RecordingObserver.$traceID.withValue("trace-42") {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            }
            _ = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
        }
        let entries = observer.all
        #expect(entries.count == 2)
        #expect(entries[0].startTrace == "trace-42" && entries[0].finishTrace == "trace-42")
        #expect(entries[1].startTrace == nil && entries[1].finishTrace == nil)
    }

    @Test("The wait for the writer is measured separately from the work")
    func connectionWait() async throws {
        let observer = RecordingObserver()
        try await withDatabase(configure: { $0.observer = observer }) { database, _ in
            let latch = SQLiteTestLatch()
            let holding = Task {
                try await database.write { (tx) throws(SQLiteError) in
                    try tx.execute("INSERT INTO items (name) VALUES ('first')")
                    latch.blockingWait()
                }
            }
            #expect(await latch.waitUntilEntered())
            let waiting = Task {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('second')") }
            }
            // Let the second write queue behind the first, then release the first.
            for _ in 0..<200 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(30))
            latch.open()
            try await holding.value
            try await waiting.value
        }
        let writes = observer.all.filter { $0.kind == .write }
        #expect(writes.count == 2)
        #expect(writes.contains { $0.wait >= .milliseconds(20) })
    }

    @Test("Without an observer nothing changes")
    func noObserver() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            #expect(database.configuration.observer == nil)
        }
    }

    @Test("Fault injection: an unknown commit outcome that the probe resolves as not durable")
    func injectedUnknownCommit() async throws {
        let observer = RecordingObserver()
        try await withDatabase(configure: { $0.observer = observer }) { database, _ in
            try await database.injectFault(.commitOutcomeUnknown)
            let outcome = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO items (name) VALUES ('maybe')")
            }
            guard case .unknown(let error) = outcome else { Issue.record("got \(outcome)"); return }
            #expect(error.code == .commitOutcomeUnknown)
            let durable = try await database.resolveCommit { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT 1 FROM items WHERE name = 'maybe'") != nil
            }
            #expect(!durable)
            // The fault fired once; the next write commits normally.
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('sure')") }
        }
        #expect(observer.all.map(\.outcome).contains("failed:commitOutcomeUnknown"))
    }
}
