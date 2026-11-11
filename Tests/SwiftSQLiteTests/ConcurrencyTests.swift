// SPDX-License-Identifier: Apache-2.0

@testable import SwiftSQLite
import SwiftSQLiteTesting
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class Gauge: Sendable {
    private let state = Mutex((current: 0, peak: 0))
    func enter() { state.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) } }
    func leave() { state.withLock { $0.current -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

@Suite("Concurrency, isolation and cancellation")
struct ConcurrencyTests {
    @Test("A read transaction keeps one WAL snapshot while a write commits")
    func snapshotIsolation() async throws {
        try await withDatabase { database, _ in
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
            let latch = SQLiteTestLatch()
            let reading = Task {
                try await database.read { (tx) throws(SQLiteError) -> (SQLiteValue?, SQLiteValue?) in
                    let before = try tx.scalar("SELECT count(*) FROM items")
                    latch.blockingWait()
                    let after = try tx.scalar("SELECT count(*) FROM items")
                    return (before, after)
                }
            }
            #expect(await latch.waitUntilEntered())
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('b')") }
            latch.open()
            let (before, after) = try await reading.value
            #expect(before == .integer(1))
            #expect(after == .integer(1))
            let now = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(now == .integer(2))
        }
    }

    @Test("The reader pool bounds concurrent reads", arguments: [0, 1, 4])
    func readerPoolBound(readers: Int) async throws {
        let gauge = Gauge()
        try await withDatabase(configure: { $0.readerCount = readers }) { database, _ in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        try await database.read { (tx) throws(SQLiteError) in
                            gauge.enter()
                            defer { gauge.leave() }
                            usleep(5_000)
                            _ = try tx.scalar("SELECT count(*) FROM items")
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(gauge.peak <= max(readers, 1))
        #expect(gauge.peak >= 1)
    }

    @Test("Writes are serialized on the single writer")
    func writerSerialized() async throws {
        let gauge = Gauge()
        try await withDatabase { database, _ in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        try await database.write { (tx) throws(SQLiteError) in
                            gauge.enter()
                            defer { gauge.leave() }
                            try tx.execute("INSERT INTO items (name) VALUES (?)", [.text("w\(index)")])
                        }
                    }
                }
                try await group.waitForAll()
            }
            let count = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(count == .integer(16))
        }
        #expect(gauge.peak == 1)
    }

    @Test("Cancelling a task waiting for a busy writer slot throws .interrupted promptly")
    func cancelWhileWaitingForSlot() async throws {
        try await withDatabase { database, _ in
            let latch = SQLiteTestLatch()
            let holder = Task {
                try await database.write { (_) throws(SQLiteError) in latch.blockingWait() }
            }
            #expect(await latch.waitUntilEntered())
            let waiting = Task {
                try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('never')") }
            }
            try await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            waiting.cancel()
            let result = await waiting.result
            #expect(ContinuousClock.now - start < .seconds(2))
            guard case .failure(let error) = result else { Issue.record("waiting write succeeded"); latch.open(); return }
            #expect(error as? SQLiteError == .interrupted)
            latch.open()
            try await holder.value
            let count = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
            #expect(count == .integer(0))
        }
    }

    @Test("Cancellation during a busy wait ends the wait early with .interrupted")
    func cancelDuringBusyWait() async throws {
        try await withDatabase { database, directory in
            var otherConfig = SQLiteConfiguration.singleConnection(path: directory.file("test.sqlite"))
            otherConfig.busyTimeout = .seconds(30)
            let other = try await SQLiteDatabase.open(otherConfig, migrations: sampleMigrations)
            let latch = SQLiteTestLatch()
            let holder = Task {
                try await database.write { (_) throws(SQLiteError) in latch.blockingWait(timeout: .seconds(20)) }
            }
            #expect(await latch.waitUntilEntered())
            let blocked = Task {
                try await other.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            }
            try await Task.sleep(for: .milliseconds(200))
            let start = ContinuousClock.now
            blocked.cancel()
            let result = await blocked.result
            let latency = ContinuousClock.now - start
            latch.open()
            try await holder.value
            await other.close()
            #expect(latency < .seconds(2), "busy wait ignored cancellation for \(latency)")
            guard case .failure(let error) = result else { Issue.record("blocked write succeeded"); return }
            #expect(error as? SQLiteError == .interrupted)
        }
    }

    @Test("Busy timeout is bounded and yields typed .busy")
    func busyTimeoutBounded() async throws {
        try await withDatabase { database, directory in
            var otherConfig = SQLiteConfiguration(path: directory.file("test.sqlite"))
            otherConfig.busyTimeout = .milliseconds(100)
            let other = try await SQLiteDatabase.open(otherConfig, migrations: sampleMigrations)
            let latch = SQLiteTestLatch()
            let holder = Task { try await database.write { (_) throws(SQLiteError) in latch.blockingWait() } }
            #expect(await latch.waitUntilEntered())
            let start = ContinuousClock.now
            let error = await caught {
                try await other.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('x')") }
            }
            let elapsed = ContinuousClock.now - start
            latch.open()
            try await holder.value
            await other.close()
            guard case .busy(let details) = error else { Issue.record("got \(String(describing: error))"); return }
            #expect(details.code.primary == .busy)
            #expect(elapsed >= .milliseconds(80) && elapsed < .seconds(3), "elapsed \(elapsed)")
        }
    }

    @Test("Default busy timeout is 5 seconds")
    func defaultBusyTimeout() {
        #expect(SQLiteConfiguration(path: "/x").busyTimeout == .seconds(5))
        #expect(SQLiteConfiguration(path: "/x").readerCount == 4)
        #expect(SQLiteConfiguration.singleConnection(path: "/x").readerCount == 0)
    }
}
