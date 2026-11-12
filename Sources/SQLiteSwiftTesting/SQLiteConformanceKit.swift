// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import SQLiteSwift

/// A generic conformance kit for SQLiteSwift setups.
///
/// Consumers run it with their own migrations and configuration (for example from a
/// domain store's test suite). Each check uses a fresh temporary directory and its own
/// probe tables (`sqliteswift_probe*`), so it never touches real data.
///
/// ```swift
/// let kit = SQLiteConformanceKit(migrations: MyStore.migrations) { path in
///     var configuration = SQLiteConfiguration(path: path)
///     configuration.readerCount = 2
///     return configuration
/// }
/// let results = await kit.runAll()
/// #expect(results.allSatisfy { $0.outcome == .passed })
/// ```
public struct SQLiteConformanceKit: Sendable {
    /// One check the kit runs.
    ///
    /// `Check` is a struct, so new checks can be added in minor releases without
    /// breaking a `switch`; give it a `default` branch. ``allCases`` lists every check
    /// in the order ``runAll()`` runs them.
    public struct Check: Sendable, Hashable, CaseIterable, CustomStringConvertible {
        enum Kind: String, Sendable, CaseIterable {
            case migrations, schemaTooNew, compareAndSetConflict, commitFailure, commitOutcome
            case busyContention, cancellationInterrupt, operationLimits, walCheckpoint
            case recoveryAfterAbortedWrite, diskFull, settingsVerification, fileIdentity
        }

        let kind: Kind

        /// A stable, machine-readable name, for example `"migrations"`.
        public var name: String { kind.rawValue }
        public var description: String { name }

        /// Every check, in the order ``SQLiteConformanceKit/runAll()`` runs them.
        public static var allCases: [Check] { Kind.allCases.map(Check.init(kind:)) }

        /// Migrations apply once, in order; reopening runs none; a partial upgrade runs
        /// only the rest; a failing migration rolls back alone.
        public static let migrations = Check(kind: .migrations)
        /// A database newer than the migrations is refused and left byte-for-byte untouched.
        public static let schemaTooNew = Check(kind: .schemaTooNew)
        /// Compare-and-set returns updated, conflict, guard-failed and not-found results;
        /// concurrent updates of one version let exactly one win.
        public static let compareAndSetConflict = Check(kind: .compareAndSetConflict)
        /// A `COMMIT` rejected while the transaction is still open (a deferred foreign-key
        /// violation) is reported as that typed error, not as an unknown outcome, and
        /// nothing is committed. Needs `foreignKeys` on.
        public static let commitFailure = Check(kind: .commitFailure)
        /// `writeReportingOutcome` reports committed and not-committed writes, and
        /// `resolveCommit` agrees with what is durable.
        public static let commitOutcome = Check(kind: .commitOutcome)
        /// A second database on the same file gets `.busy` after its busy timeout while
        /// the first holds the write lock, then succeeds after it's released.
        public static let busyContention = Check(kind: .busyContention)
        /// Cancelling a running read or write interrupts it with `.interrupted`, rolls
        /// back, and leaves the database usable.
        public static let cancellationInterrupt = Check(kind: .cancellationInterrupt)
        /// Instruction budgets and deadlines stop reads and writes with typed errors,
        /// roll writes back, and never affect the next operation.
        public static let operationLimits = Check(kind: .operationLimits)
        /// WAL checkpoints copy all frames back, and `.truncate` empties the WAL file.
        public static let walCheckpoint = Check(kind: .walCheckpoint)
        /// A crash image taken in the middle of an uncommitted write recovers to the last
        /// committed state with a passing integrity check.
        public static let recoveryAfterAbortedWrite = Check(kind: .recoveryAfterAbortedWrite)
        /// `max_page_count` simulates a full disk: the write fails with `.full`, rolls
        /// back, and the database keeps working.
        public static let diskFull = Check(kind: .diskFull)
        /// The settings read back from SQLite match the configuration.
        public static let settingsVerification = Check(kind: .settingsVerification)
        /// A file identity (the configured one, or a probe identity) is written to a new
        /// file, accepted on reopen, and a different identity is refused without
        /// changing the file.
        public static let fileIdentity = Check(kind: .fileIdentity)
    }

    /// The outcome of one check.
    public enum Outcome: Sendable, Hashable {
        case passed
        case failed(String)
        case skipped(String)
    }

    /// The result of one check, with notes on what was observed.
    public struct CheckResult: Sendable, Hashable {
        public let check: Check
        public let outcome: Outcome
        public let notes: [String]
    }

    public let migrations: [SQLiteMigration]
    public let makeConfiguration: @Sendable (_ path: String) -> SQLiteConfiguration

    /// - Parameters:
    ///   - migrations: The consumer's migrations, numbered `1...n`.
    ///   - makeConfiguration: Builds the configuration for a database at a path. The
    ///     kit changes only `busyTimeout` for the second database in `busyContention`.
    public init(
        migrations: [SQLiteMigration] = [],
        makeConfiguration: @escaping @Sendable (_ path: String) -> SQLiteConfiguration = {
            SQLiteConfiguration(path: $0)
        }
    ) {
        self.migrations = migrations
        self.makeConfiguration = makeConfiguration
    }

    /// Runs every check in declaration order.
    public func runAll() async -> [CheckResult] {
        var results: [CheckResult] = []
        for check in Check.allCases {
            results.append(await run(check))
        }
        return results
    }

    /// Runs one check.
    public func run(_ check: Check) async -> CheckResult {
        let notes = Notes()
        do {
            let directory = try SQLiteTemporaryDirectory(prefix: "sqliteswift-conformance")
            defer { directory.remove() }
            let context = Context(kit: self, directory: directory, notes: notes)
            if let reason = context.skipReason(for: check) {
                return CheckResult(check: check, outcome: .skipped(reason), notes: notes.all)
            }
            switch check.kind {
            case .migrations: try await context.checkMigrations()
            case .schemaTooNew: try await context.checkSchemaTooNew()
            case .compareAndSetConflict: try await context.checkCompareAndSet()
            case .commitFailure: try await context.checkCommitFailure()
            case .commitOutcome: try await context.checkCommitOutcome()
            case .busyContention: try await context.checkBusyContention()
            case .cancellationInterrupt: try await context.checkCancellation()
            case .operationLimits: try await context.checkOperationLimits()
            case .walCheckpoint: try await context.checkWALCheckpoint()
            case .recoveryAfterAbortedWrite: try await context.checkRecovery()
            case .diskFull: try await context.checkDiskFull()
            case .settingsVerification: try await context.checkSettings()
            case .fileIdentity: try await context.checkFileIdentity()
            }
            return CheckResult(check: check, outcome: .passed, notes: notes.all)
        } catch let failure as ConformanceFailure {
            return CheckResult(check: check, outcome: .failed(failure.message), notes: notes.all)
        } catch {
            return CheckResult(check: check, outcome: .failed("unexpected error: \(error)"), notes: notes.all)
        }
    }
}

// MARK: - Implementation

struct ConformanceFailure: Error {
    let message: String
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ConformanceFailure(message: message()) }
}

private final class Notes: Sendable {
    private let storage = Mutex<[String]>([])
    func add(_ note: String) { storage.withLock { $0.append(note) } }
    var all: [String] { storage.withLock { $0 } }
}

private final class Counter: Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.add(1, ordering: .sequentiallyConsistent) }
    var current: Int { value.load(ordering: .sequentiallyConsistent) }
}

private let probeTable = "sqliteswift_probe"
private let createProbe =
    "CREATE TABLE IF NOT EXISTS sqliteswift_probe (id INTEGER PRIMARY KEY, version INTEGER NOT NULL DEFAULT 1, payload BLOB)"
private let longQuery =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000000000) SELECT max(x) FROM c"

private struct Context {
    let kit: SQLiteConformanceKit
    let directory: SQLiteTemporaryDirectory
    let notes: Notes

    var migrations: [SQLiteMigration] { kit.migrations }

    func configuration(_ name: String = "conformance.sqlite") -> SQLiteConfiguration {
        kit.makeConfiguration(directory.file(name))
    }

    var isInMemory: Bool {
        if case .inMemory = configuration().storage { return true }
        return false
    }

    func path(of configuration: SQLiteConfiguration) -> String? {
        if case .file(let path) = configuration.storage { return path }
        return nil
    }

    func skipReason(for check: SQLiteConformanceKit.Check) -> String? {
        switch check.kind {
        case .schemaTooNew, .busyContention, .walCheckpoint, .recoveryAfterAbortedWrite:
            isInMemory ? "needs a file database" : nil
        case .commitFailure:
            configuration().foreignKeys ? nil : "needs foreignKeys enabled"
        default:
            nil
        }
    }

    func open(
        _ configuration: SQLiteConfiguration, _ migrations: [SQLiteMigration]? = nil
    ) async throws -> SQLiteDatabase {
        let database = try await SQLiteDatabase.open(configuration, migrations: migrations ?? self.migrations)
        try await database.write { (tx) throws(SQLiteError) in try tx.execute(createProbe) }
        return database
    }

    func count(_ database: SQLiteDatabase, _ whereClause: String = "1") async throws -> Int64 {
        try await database.read { (tx) throws(SQLiteError) -> Int64 in
            try tx.queryOne("SELECT count(*) FROM \(probeTable) WHERE \(whereClause)")!.integer(0)
        }
    }

    // MARK: migrations

    func checkMigrations() async throws {
        let counter = Counter()
        let counted = migrations.map { migration in
            SQLiteMigration(version: migration.version, name: migration.name) { (tx) throws(SQLiteError) in
                counter.increment()
                try migration.apply(in: tx)
            }
        }
        let n = migrations.count
        let first = try await SQLiteDatabase.open(configuration(), migrations: counted)
        let version = try await first.schemaVersion()
        await first.close()
        try require(version == n, "schema version after first open is \(version), expected \(n)")
        try require(counter.current == n, "first open ran \(counter.current) migrations, expected \(n)")
        notes.add("fresh open applied \(n) migration(s)")

        if !isInMemory {
            let again = try await SQLiteDatabase.open(configuration(), migrations: counted)
            await again.close()
            try require(counter.current == n, "reopening ran migrations again (\(counter.current - n) extra)")
            notes.add("reopen applied 0 migrations")

            if n >= 2 {
                let partialConfig = configuration("partial.sqlite")
                let partial = try await SQLiteDatabase.open(partialConfig, migrations: Array(counted.prefix(n - 1)))
                await partial.close()
                let before = counter.current
                let upgraded = try await SQLiteDatabase.open(partialConfig, migrations: counted)
                let upgradedVersion = try await upgraded.schemaVersion()
                await upgraded.close()
                try require(counter.current - before == 1, "upgrade from \(n - 1) ran \(counter.current - before) migrations, expected 1")
                try require(upgradedVersion == n, "upgraded schema version is \(upgradedVersion), expected \(n)")
                notes.add("partial upgrade \(n - 1) -> \(n) applied 1 migration")
            }
        }

        // A failing migration rolls back alone; earlier ones stay committed.
        let good = SQLiteMigration(version: n + 1, name: "probe ok", sql: createProbe)
        let bad = SQLiteMigration(version: n + 2, name: "probe failing") { (tx) throws(SQLiteError) in
            try tx.execute("CREATE TABLE sqliteswift_probe_failed (id INTEGER)")
            try tx.execute("INSERT INTO sqliteswift_probe_missing VALUES (1)")
        }
        let failingConfig = configuration("failing.sqlite")
        do {
            let database = try await SQLiteDatabase.open(failingConfig, migrations: migrations + [good, bad])
            await database.close()
            throw ConformanceFailure(message: "a failing migration did not fail the open")
        } catch let error as SQLiteError {
            guard error.code == .migrationFailed, error.migrationVersion == n + 2 else {
                throw ConformanceFailure(message: "expected migrationFailed(version: \(n + 2)), got \(error)")
            }
        }
        if !isInMemory {
            let database = try await SQLiteDatabase.open(failingConfig, migrations: migrations + [good])
            let version = try await database.schemaVersion()
            let leftover = try await database.read { (tx) throws(SQLiteError) in
                try tx.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'sqliteswift_probe_failed'")
            }
            await database.close()
            try require(version == n + 1, "after a failed migration the version is \(version), expected \(n + 1)")
            try require(leftover == .integer(0), "the failed migration's table survived the rollback")
            notes.add("failing migration \(n + 2) rolled back; version stayed \(n + 1)")
        }
    }

    // MARK: schemaTooNew

    func checkSchemaTooNew() async throws {
        let config = configuration()
        let n = migrations.count
        let database = try await open(config)
        try await database.write { (tx) throws(SQLiteError) in try tx.execute("PRAGMA user_version = \(n + 1)") }
        await database.close()
        let path = path(of: config)!
        let before = SQLiteCrashImage.contents(path)
        let walBefore = FileManager.default.fileExists(atPath: path + "-wal")
        do {
            let reopened = try await SQLiteDatabase.open(config, migrations: migrations)
            await reopened.close()
            throw ConformanceFailure(message: "a database at version \(n + 1) was opened by code that knows \(n)")
        } catch let error as SQLiteError {
            guard error.code == .schemaTooNew, error.databaseVersion == n + 1, error.supportedVersion == n else {
                throw ConformanceFailure(message: "expected schemaTooNew(\(n + 1), \(n)), got \(error)")
            }
        }
        let after = SQLiteCrashImage.contents(path)
        try require(before != nil && before == after, "the refused database file changed")
        let walAfter = FileManager.default.fileExists(atPath: path + "-wal")
        try require(walBefore == walAfter, "the refused open left a WAL file behind")
        notes.add("refused version \(n + 1) with \(before?.count ?? 0) bytes unchanged")
    }

    // MARK: compare-and-set

    func checkCompareAndSet() async throws {
        let database = try await open(configuration())
        defer { Task { await database.close() } }
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id, version, payload) VALUES (1, 1, x'00')")
        }
        let first = try await database.write { (tx) throws(SQLiteError) in
            try tx.compareAndSet(table: "sqliteswift_probe", id: 1, expectedVersion: 1,
                                 assignments: [SQLiteAssignment("payload", .blob([1]))])
        }
        try require(first == .updated(newVersion: 2), "first CAS returned \(first), expected updated(2)")
        let stale = try await database.write { (tx) throws(SQLiteError) in
            try tx.compareAndSet(table: "sqliteswift_probe", id: 1, expectedVersion: 1,
                                 assignments: [SQLiteAssignment("payload", .blob([9]))])
        }
        try require(stale == .conflict(currentVersion: 2), "stale CAS returned \(stale), expected conflict(2)")
        let missing = try await database.write { (tx) throws(SQLiteError) in
            try tx.compareAndSet(table: "sqliteswift_probe", id: 999, expectedVersion: 1)
        }
        try require(missing == .notFound, "CAS on a missing row returned \(missing), expected notFound")
        let payload = try await database.read { (tx) throws(SQLiteError) in
            try tx.queryOne("SELECT payload FROM sqliteswift_probe WHERE id = 1")!.blob(0)
        }
        try require(payload == [1], "the stale CAS changed the payload")

        // Concurrent writers with the same expected version: exactly one wins.
        let contenders = 8
        let results = try await withThrowingTaskGroup(of: SQLiteCompareAndSetResult.self) { group in
            for index in 0..<contenders {
                group.addTask {
                    try await database.write { (tx) throws(SQLiteError) in
                        try tx.compareAndSet(table: "sqliteswift_probe", id: 1, expectedVersion: 2,
                                             assignments: [SQLiteAssignment("payload", .blob([UInt8(index)]))])
                    }
                }
            }
            var collected: [SQLiteCompareAndSetResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        let winners = results.filter { $0 == .updated(newVersion: 3) }.count
        let losers = results.filter { $0 == .conflict(currentVersion: 3) }.count
        try require(winners == 1 && losers == contenders - 1,
                    "\(contenders) concurrent CAS gave \(winners) winners and \(losers) conflicts")
        notes.add("\(contenders) concurrent CAS: 1 updated, \(losers) conflicts")

        // A typed guard: same version, but the guard is false → guardFailed, unchanged.
        let guarded = try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id, version, payload) VALUES (2, 1, NULL)")
            return try tx.compareAndSet(table: "sqliteswift_probe", id: 2, expectedVersion: 1,
                                        assignments: [SQLiteAssignment("payload", .blob([2]))],
                                        alsoRequire: .isNotNull("payload"))
        }
        try require(guarded == .guardFailed(currentVersion: 1), "guarded CAS returned \(guarded), expected guardFailed(1)")
        let stillNull = try await database.read { (tx) throws(SQLiteError) in
            try tx.scalar("SELECT payload FROM sqliteswift_probe WHERE id = 2")
        }
        try require(stillNull == .null, "a failed guard changed the row")
        notes.add("guarded CAS: guardFailed leaves the row unchanged")
    }

    // MARK: commit failure

    func checkCommitFailure() async throws {
        let database = try await open(configuration())
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("""
                CREATE TABLE IF NOT EXISTS sqliteswift_probe_child (
                    id INTEGER PRIMARY KEY,
                    parent INTEGER REFERENCES sqliteswift_probe(id) DEFERRABLE INITIALLY DEFERRED)
                """)
        }
        var observed: SQLiteError?
        do {
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe_child (id, parent) VALUES (1, 4242)")
            }
        } catch {
            observed = error
        }
        guard let observed, observed.code == .constraint, let details = observed.details else {
            await database.close()
            throw ConformanceFailure(message: "a COMMIT rejected by a deferred foreign key gave \(String(describing: observed)), expected .constraint")
        }
        let rows = try await database.read { (tx) throws(SQLiteError) in
            try tx.queryOne("SELECT count(*) FROM sqliteswift_probe_child")!.integer(0)
        }
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (4242)")
            try tx.execute("INSERT INTO sqliteswift_probe_child (id, parent) VALUES (1, 4242)")
        }
        await database.close()
        try require(rows == 0, "the rejected COMMIT left \(rows) rows")
        notes.add("COMMIT rejected with code \(details.code.rawValue) while open: typed, not committed, database usable")
    }

    // MARK: commit outcome

    func checkCommitOutcome() async throws {
        let database = try await open(configuration())
        let committed = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (5151)").changedRows
        }
        let duplicate = await database.writeReportingOutcome { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (5252)")
            try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (5151)")
        }
        let marker = { (id: Int64) -> @Sendable (SQLiteTransaction) throws(SQLiteError) -> Bool in
            { (tx) throws(SQLiteError) in
                try tx.queryOne("SELECT 1 FROM sqliteswift_probe WHERE id = ?", [.integer(id)]) != nil
            }
        }
        let foundCommitted = try await database.resolveCommit(marker(5151))
        let foundRolledBack = try await database.resolveCommit(marker(5252))
        await database.close()
        try require(committed.value == 1, "a successful write reported \(committed)")
        guard case .notCommitted(let error) = duplicate, error.code == .constraint else {
            throw ConformanceFailure(message: "a failing write reported \(duplicate), expected notCommitted(.constraint)")
        }
        try require(foundCommitted, "resolveCommit did not find a committed marker")
        try require(!foundRolledBack, "resolveCommit found the marker of a rolled-back write")
        notes.add("committed and notCommitted reported; resolveCommit matches durable state")
    }

    // MARK: operation limits

    func checkOperationLimits() async throws {
        let database = try await open(configuration())
        let budget = SQLiteOperationLimits(maxInstructions: 10_000)
        let readError = await stopError {
            try await database.read(limits: budget) { (tx) throws(SQLiteError) in try tx.scalar(longQuery) }
        }
        let writeError = await stopError {
            try await database.write(limits: budget) { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (5353)")
                _ = try tx.scalar(longQuery)
            }
        }
        let start = ContinuousClock.now
        let deadlineError = await stopError {
            try await database.read(limits: SQLiteOperationLimits(timeout: .milliseconds(100))) {
                (tx) throws(SQLiteError) in try tx.scalar(longQuery)
            }
        }
        let elapsed = ContinuousClock.now - start
        let leaked = try await count(database, "id = 5353")
        let after = try await database.read { (tx) throws(SQLiteError) in try tx.scalar("SELECT 1") }
        await database.close()
        try require(readError?.code == .instructionLimitExceeded, "a budgeted read gave \(String(describing: readError))")
        try require(writeError?.code == .instructionLimitExceeded, "a budgeted write gave \(String(describing: writeError))")
        try require(deadlineError?.code == .deadlineExceeded, "a timed read gave \(String(describing: deadlineError))")
        try require(elapsed < .seconds(5), "the deadline stopped the read only after \(elapsed)")
        try require(leaked == 0, "the stopped write's insert was committed")
        try require(after == .integer(1), "the database was unusable after a stop")
        notes.add("budget and deadline stops typed; deadline honored after \(elapsed); write rolled back")
    }

    private func stopError<T>(_ operation: () async throws -> T) async -> SQLiteError? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? SQLiteError
        }
    }

    // MARK: settings verification

    func checkSettings() async throws {
        let config = configuration()
        let database = try await open(config)
        let settings = try await database.effectiveSettings()
        await database.close()
        if !isInMemory {
            try require(settings.journalMode == "wal", "journal_mode is \(settings.journalMode), expected wal")
        }
        let synchronous = config.synchronous == .full ? 2 : 1
        try require(settings.synchronous == synchronous, "synchronous is \(settings.synchronous), expected \(synchronous)")
        try require(settings.foreignKeys == config.foreignKeys, "foreign_keys is \(settings.foreignKeys)")
        try require(!settings.trustedSchema, "trusted_schema is on")
        try require(settings.maxLength == config.limits.hardMaxResultBytes,
                    "SQLITE_LIMIT_LENGTH is \(settings.maxLength), expected \(config.limits.hardMaxResultBytes)")
        #if canImport(Darwin)
        try require(settings.fullFSync == config.appleFullFSync, "fullfsync is \(settings.fullFSync)")
        try require(settings.checkpointFullFSync == config.appleFullFSync, "checkpoint_fullfsync is \(settings.checkpointFullFSync)")
        #endif
        notes.add("SQLite \(settings.sqliteVersion), journal \(settings.journalMode), synchronous \(settings.synchronous), fullfsync \(settings.fullFSync)")
    }

    // MARK: file identity

    func checkFileIdentity() async throws {
        var config = configuration("identity.sqlite")
        let identity = config.fileIdentity ?? SQLiteFileIdentity(applicationID: 0x5351_4B54)
        config.fileIdentity = identity
        let database = try await open(config)
        let settings = try await database.effectiveSettings()
        await database.close()
        try require(settings.applicationID == identity.applicationID,
                    "application_id is \(settings.applicationID), expected \(identity.applicationID)")
        if let pageSize = identity.pageSize {
            try require(settings.pageSize == pageSize, "page_size is \(settings.pageSize), expected \(pageSize)")
        }
        guard !isInMemory, let path = path(of: config) else {
            notes.add("identity applied to a new in-memory database")
            return
        }
        let reopened = try await SQLiteDatabase.open(config, migrations: migrations)
        await reopened.close()
        let before = SQLiteCrashImage.contents(path)
        var wrong = config
        wrong.fileIdentity = SQLiteFileIdentity(applicationID: identity.applicationID &+ 1)
        do {
            let opened = try await SQLiteDatabase.open(wrong, migrations: migrations)
            await opened.close()
            throw ConformanceFailure(message: "a file with another application_id was opened")
        } catch let error as SQLiteError {
            try require(error.code == .fileIdentityMismatch, "a wrong identity gave \(error), expected fileIdentityMismatch")
        }
        try require(SQLiteCrashImage.contents(path) == before, "the refused file changed")
        notes.add("identity written, accepted on reopen, wrong identity refused without changes")
    }

    // MARK: busy contention

    func checkBusyContention() async throws {
        let holderConfig = configuration()
        var waiterConfig = configuration()
        let timeout = Duration.milliseconds(300)
        waiterConfig.busyTimeout = timeout
        let holder = try await open(holderConfig)
        let waiter = try await SQLiteDatabase.open(waiterConfig, migrations: migrations)
        let latch = SQLiteTestLatch()
        let holding = Task {
            try await holder.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe (payload) VALUES (x'01')")
                latch.blockingWait()
            }
        }
        defer { latch.open() }
        try require(await latch.waitUntilEntered(), "the holder never acquired the write lock")
        let start = ContinuousClock.now
        var observed: SQLiteError?
        do {
            try await waiter.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe (payload) VALUES (x'02')")
            }
        } catch {
            observed = error
        }
        let elapsed = ContinuousClock.now - start
        latch.open()
        try await holding.value
        guard observed?.code == .busy else {
            throw ConformanceFailure(message: "expected .busy while another connection writes, got \(String(describing: observed))")
        }
        try require(elapsed >= timeout * 0.8, "busy came after \(elapsed), before the \(timeout) timeout")
        try require(elapsed < timeout + .seconds(5), "busy took \(elapsed), far beyond the \(timeout) timeout")
        try await waiter.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (payload) VALUES (x'03')")
        }
        let rows = try await count(waiter)
        await waiter.close()
        await holder.close()
        try require(rows == 2, "expected 2 committed rows after contention, found \(rows)")
        notes.add("busy after \(elapsed) with a \(timeout) timeout; retry succeeded")
    }

    // MARK: cancellation

    func checkCancellation() async throws {
        let database = try await open(configuration())
        // A long read.
        let reading = Task {
            try await database.read { (tx) throws(SQLiteError) in try tx.scalar(longQuery) }
        }
        try await Task.sleep(for: .milliseconds(150))
        let cancelledAt = ContinuousClock.now
        reading.cancel()
        let readResult = await reading.result
        let readLatency = ContinuousClock.now - cancelledAt
        guard case .failure(let readError) = readResult, (readError as? SQLiteError)?.code == .interrupted else {
            await database.close()
            throw ConformanceFailure(message: "a cancelled read returned \(readResult), expected .interrupted")
        }
        try require(readLatency < .seconds(5), "the cancelled read took \(readLatency) to stop")

        // A long write: its insert must roll back.
        let writing = Task {
            try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (4242, x'42')")
                return try tx.scalar(longQuery)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        writing.cancel()
        let writeResult = await writing.result
        guard case .failure(let writeError) = writeResult, (writeError as? SQLiteError)?.code == .interrupted else {
            await database.close()
            throw ConformanceFailure(message: "a cancelled write returned \(writeResult), expected .interrupted")
        }
        let leaked = try await count(database, "id = 4242")
        try require(leaked == 0, "the cancelled write's insert was committed")

        // An already-cancelled task never starts its transaction.
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await database.write { (tx) throws(SQLiteError) in
                try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (4343)")
            }
        }
        let preResult = await preCancelled.result
        guard case .failure(let preError) = preResult, (preError as? SQLiteError)?.code == .interrupted else {
            await database.close()
            throw ConformanceFailure(message: "a pre-cancelled write returned \(preResult), expected .interrupted")
        }

        // The database still works.
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id) VALUES (1)")
        }
        let rows = try await count(database)
        await database.close()
        try require(rows == 1, "expected 1 row after cancellations, found \(rows)")
        notes.add("cancelled read stopped after \(readLatency)")
    }

    // MARK: WAL checkpoint

    func checkWALCheckpoint() async throws {
        let config = configuration()
        let path = path(of: config)!
        let database = try await open(config)
        try await database.write { (tx) throws(SQLiteError) in
            for index in 0..<200 {
                try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (?, zeroblob(1024))", [.integer(Int64(index))])
            }
        }
        let walBefore = SQLiteCrashImage.fileSize(path + "-wal") ?? 0
        try require(walBefore > 0, "the WAL is empty after a write; is the database in WAL mode?")
        let passive = try await database.checkpoint(.passive)
        try require(passive.walFrames > 0 && passive.checkpointedFrames == passive.walFrames,
                    "passive checkpoint copied \(passive.checkpointedFrames) of \(passive.walFrames) frames")
        try await database.checkpoint(.truncate)
        let walAfter = SQLiteCrashImage.fileSize(path + "-wal") ?? 0
        try require(walAfter == 0, "the WAL has \(walAfter) bytes after a truncate checkpoint")
        let rows = try await count(database)
        await database.close()
        try require(rows == 200, "expected 200 rows after checkpoints, found \(rows)")
        notes.add("WAL \(walBefore) bytes, \(passive.walFrames) frames checkpointed, truncated to 0")
    }

    // MARK: recovery

    func checkRecovery() async throws {
        let config = configuration()
        let path = path(of: config)!
        let database = try await open(config)
        try await database.write { (tx) throws(SQLiteError) in
            for index in 1...10 {
                try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (?, x'01')", [.integer(Int64(index))])
            }
        }
        let committedWALBytes = SQLiteCrashImage.fileSize(path + "-wal") ?? 0
        let (cacheSize, cacheSpill) = try await database.write { (tx) throws(SQLiteError) in
            (try tx.queryOne("PRAGMA cache_size")!.integer(0), try tx.queryOne("PRAGMA cache_spill")!.integer(0))
        }
        let latch = SQLiteTestLatch()
        let crashPath = directory.file("crash-image.sqlite")
        let aborting = Task {
            try await database.write { (tx) throws(SQLiteError) in
                // A tiny page cache and spill threshold make SQLite write uncommitted
                // pages into the WAL, so the crash image holds frames without a commit.
                try tx.execute("PRAGMA cache_size = 2")
                try tx.execute("PRAGMA cache_spill = 2")
                for index in 100..<400 {
                    try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (?, zeroblob(4096))", [.integer(Int64(index))])
                }
                latch.blockingWait()
                throw SQLiteError.invalidArgument("conformance: simulated abort mid-write")
            }
        }
        defer { latch.open() }
        try require(await latch.waitUntilEntered(), "the aborting write never reached its midpoint")
        let walBytes = try SQLiteCrashImage.capture(databasePath: path, to: crashPath)
        latch.open()
        let abortResult = await aborting.result
        guard case .failure = abortResult else {
            throw ConformanceFailure(message: "the simulated abort committed")
        }
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("PRAGMA cache_size = \(cacheSize)")
            try tx.execute("PRAGMA cache_spill = \(cacheSpill)")
        }
        let liveRows = try await count(database)
        await database.close()
        try require(liveRows == 10, "after the aborted write the live database has \(liveRows) rows, expected 10")
        try require(walBytes > committedWALBytes + 100 * 4096,
                    "only \(walBytes) WAL bytes at the crash point (\(committedWALBytes) committed); uncommitted pages did not spill")

        let recovered = try await SQLiteDatabase.open(kit.makeConfiguration(crashPath), migrations: migrations)
        let integrity = try await recovered.read { (tx) throws(SQLiteError) in
            try tx.scalar("PRAGMA integrity_check")
        }
        let recoveredRows = try await count(recovered)
        let uncommitted = try await count(recovered, "id >= 100")
        await recovered.close()
        try require(integrity == .text("ok"), "integrity_check on the crash image returned \(String(describing: integrity))")
        try require(recoveredRows == 10 && uncommitted == 0,
                    "the crash image recovered \(recoveredRows) rows (\(uncommitted) uncommitted), expected 10 (0)")
        notes.add("crash image with \(walBytes) WAL bytes recovered 10 committed rows, integrity ok")
    }

    // MARK: disk full

    func checkDiskFull() async throws {
        let database = try await open(configuration())
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (1, x'01')")
            let pages = try tx.queryOne("PRAGMA page_count")!.integer(0)
            try tx.execute("PRAGMA max_page_count = \(pages + 2)")
        }
        var observed: SQLiteError?
        do {
            try await database.write { (tx) throws(SQLiteError) in
                for index in 100..<164 {
                    try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (?, zeroblob(4096))", [.integer(Int64(index))])
                }
            }
        } catch {
            observed = error
        }
        guard let observed, observed.code == .full, let details = observed.details else {
            await database.close()
            throw ConformanceFailure(message: "expected .full with max_page_count reached, got \(String(describing: observed))")
        }
        let rowsAfterFull = try await count(database)
        try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("PRAGMA max_page_count = 1073741823")
            try tx.execute("INSERT INTO sqliteswift_probe (id, payload) VALUES (2, x'02')")
        }
        let rows = try await count(database)
        await database.close()
        try require(rowsAfterFull == 1, "the failed write left \(rowsAfterFull) rows, expected 1")
        try require(rows == 2, "the database did not accept writes after SQLITE_FULL")
        notes.add("SQLITE_FULL (code \(details.code.rawValue)) rolled back; later writes succeed")
    }
}
