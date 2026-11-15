// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SQLiteSwift
import SQLiteSwiftServer
import SQLiteSwiftTesting
import Testing

#if Metrics
import MetricsTestKit
#endif
#if Tracing
import InMemoryTracing
import Tracing
#endif
#if Logging
import Logging
#endif
#if ServiceLifecycle
import ServiceLifecycle
import ServiceLifecycleTestKit
#endif

let serverMigrations = [
    SQLiteMigration(version: 1, name: "items", sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);")
]

func withServerDatabase<T>(
    observer: (any SQLiteObserver)?, _ body: (SQLiteDatabase) async throws -> T
) async throws -> T {
    let directory = try SQLiteTemporaryDirectory()
    var configuration = SQLiteConfiguration(path: directory.file("server.sqlite"))
    configuration.observer = observer
    let database = try await SQLiteDatabase.open(configuration, migrations: serverMigrations)
    do {
        let result = try await body(database)
        await database.close()
        return result
    } catch {
        await database.close()
        throw error
    }
}

/// One write, one read, one constraint failure.
func exercise(_ database: SQLiteDatabase) async throws {
    try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
    _ = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT count(*) FROM items") }
    do {
        try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('a')") }
    } catch let error as SQLiteError where error.code == .constraint {}
}

@Suite("Server bridges (package traits)")
struct ServerBridgeTests {
    @Test("SQLiteObservers runs several observers in order and unwinds in reverse")
    func combinedObservers() async throws {
        let log = SQLiteLocked([String]())
        struct Tag: SQLiteObserver {
            let name: String
            let log: SQLiteLocked<[String]>
            func operationWillStart(_ operation: SQLiteOperation) -> String { log.withLock { $0.append("start \(name)") }; return name }
            func operationDidFinish(_ report: SQLiteOperationReport, context: String) { log.withLock { $0.append("end \(context)") } }
        }
        try await withServerDatabase(observer: SQLiteObservers(Tag(name: "a", log: log), Tag(name: "b", log: log))) { database in
            _ = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
        }
        #expect(log.withLock { $0 } == ["start a", "start b", "end b", "end a"])
    }

    #if Metrics
    @Test("Metrics: durations, waits and error counts with bounded dimensions")
    func metrics() async throws {
        let metrics = TestMetrics()
        let observer = SQLiteMetricsObserver(database: "main", factory: metrics)
        try await withServerDatabase(observer: observer) { database in try await exercise(database) }
        let succeeded = try metrics.expectTimer("sqlite_operation_duration",
                                                [("operation", "write"), ("database", "main"), ("outcome", "succeeded")])
        #expect(succeeded.values.count == 1)
        let failed = try metrics.expectTimer("sqlite_operation_duration",
                                             [("operation", "write"), ("database", "main"), ("outcome", "failed")])
        #expect(failed.values.count == 1)
        _ = try metrics.expectTimer("sqlite_connection_wait", [("operation", "read"), ("database", "main")])
        let errors = try metrics.expectCounter("sqlite_operation_errors",
                                               [("operation", "write"), ("database", "main"), ("code", "constraint")])
        #expect(errors.totalValue == 1)
    }
    #endif

    #if Tracing
    @Test("Tracing: one client span per operation, a child of the caller's span, errors recorded")
    func tracing() async throws {
        let tracer = InMemoryTracer()
        let observer = SQLiteTracingObserver(tracer: tracer)
        try await withServerDatabase(observer: observer) { database in
            try await tracer.withSpan("request") { _ in try await exercise(database) }
        }
        let spans = tracer.finishedSpans
        let request = try #require(spans.first { $0.operationName == "request" })
        let database = spans.filter { $0.operationName.hasPrefix("sqlite.") }
        #expect(database.map(\.operationName) == ["sqlite.write", "sqlite.read", "sqlite.write"])
        #expect(database.allSatisfy { $0.spanContext.parentSpanID == request.spanContext.spanID })
        #expect(database.allSatisfy { $0.attributes["db.system.name"]?.toSpanAttribute() == .string("sqlite") })
        let failed = database[2]
        #expect(failed.status?.code == .error)
        #expect(failed.errors.count == 1)
        #expect(failed.attributes["db.response.status_code"]?.toSpanAttribute() == .string("constraint"))
        #expect(database[0].status == nil)
    }
    #endif

    #if Logging
    @Test("Logging: failures at error, slow operations at notice, the rest at trace")
    func logging() async throws {
        let records = SQLiteLocked([(Logger.Level, String, Logger.Metadata)]())
        var logger = Logger(label: "test") { _ in CapturingHandler(records: records) }
        logger.logLevel = .trace
        try await withServerDatabase(observer: SQLiteLoggingObserver(logger: logger, slowOperationThreshold: nil)) { database in
            try await exercise(database)
        }
        let seen = records.withLock { $0 }
        #expect(seen.map(\.0) == [.trace, .trace, .error])
        #expect(seen[2].2["sqlite.error"] == .string("constraint"))
        #expect(seen[2].2["sqlite.operation"] == .string("write"))

        records.withLock { $0.removeAll() }
        try await withServerDatabase(observer: SQLiteLoggingObserver(logger: logger, slowOperationThreshold: .zero)) { database in
            _ = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
        }
        #expect(records.withLock { $0 }.map(\.0) == [.notice])
    }

    struct CapturingHandler: LogHandler {
        let records: SQLiteLocked<[(Logger.Level, String, Logger.Metadata)]>
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) {
            records.withLock { $0.append((event.level, event.message.description, event.metadata ?? [:])) }
        }
    }
    #endif

    #if ServiceLifecycle
    @Test("Service: graceful shutdown closes the database")
    func serviceCloses() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let database = try await SQLiteDatabase.open(SQLiteConfiguration(path: directory.file("svc.sqlite")), migrations: serverMigrations)
        try await testGracefulShutdown { trigger in
            let service = SQLiteDatabaseService(database)
            let running = Task { try await service.run() }
            try await database.write { (tx) throws(SQLiteError) in try tx.execute("INSERT INTO items (name) VALUES ('up')") }
            trigger.triggerGracefulShutdown()
            try await running.value
        }
        let after = await caughtServer { try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") } }
        #expect(after?.code == .closed)
    }

    @Test("Service: scheduled maintenance runs until shutdown, then the database closes")
    func serviceMaintenance() async throws {
        let directory = try SQLiteTemporaryDirectory()
        let checkpoints = AsyncStream.makeStream(of: Void.self)
        struct Checkpoints: SQLiteObserver {
            let continuation: AsyncStream<Void>.Continuation
            func operationDidFinish(_ report: SQLiteOperationReport, context: Void) {
                if report.operation.kind == .checkpoint { continuation.yield() }
            }
        }
        var configuration = SQLiteConfiguration(path: directory.file("maint.sqlite"))
        configuration.observer = Checkpoints(continuation: checkpoints.continuation)
        let database = try await SQLiteDatabase.open(configuration, migrations: serverMigrations)
        try await testGracefulShutdown { trigger in
            let service = SQLiteDatabaseService(database, maintenance: .init(every: .milliseconds(5)))
            let running = Task { try await service.run() }
            var seen = 0
            for await _ in checkpoints.stream {
                seen += 1
                if seen == 2 { break }
            }
            trigger.triggerGracefulShutdown()
            try await running.value
        }
        let after = await caughtServer { try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") } }
        #expect(after?.code == .closed)
    }
    #endif
}

func caughtServer<T>(_ operation: () async throws -> T) async -> SQLiteError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error as? SQLiteError
    }
}
