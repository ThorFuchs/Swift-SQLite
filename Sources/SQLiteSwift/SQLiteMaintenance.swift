// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How far a backup has come.
public struct SQLiteBackupProgress: Sendable, Hashable {
    /// Pages copied so far.
    public let copiedPages: Int
    /// Pages in the source database.
    public let totalPages: Int

    public init(copiedPages: Int, totalPages: Int) {
        self.copiedPages = copiedPages
        self.totalPages = totalPages
    }
}

/// The result of ``SQLiteDatabase/integrityCheck(maxProblems:limits:)`` or
/// ``SQLiteDatabase/quickCheck(maxProblems:limits:)``.
public struct SQLiteIntegrityReport: Sendable, Hashable {
    /// What SQLite found, one entry per problem. Empty when the database is intact.
    public let problems: [String]

    /// Whether SQLite found no problem.
    public var isIntact: Bool { problems.isEmpty }

    public init(problems: [String]) {
        self.problems = problems
    }
}

extension SQLiteDatabase {
    // MARK: Backups

    /// Copies the database to a new file at `path`, page by page, from one read
    /// snapshot.
    ///
    /// The copy runs on a reader connection inside a read transaction, so writes
    /// continue while it runs and the copy shows exactly the state at its start. It
    /// uses `sqlite3_backup` in steps of `pagesPerStep` pages and checks the
    /// operation's deadline and task cancellation between steps.
    ///
    /// The destination must not exist; nothing is ever overwritten. If the backup
    /// fails or is stopped, the partial file is removed.
    ///
    /// - Parameters:
    ///   - path: The new file.
    ///   - pagesPerStep: Pages copied per step, 1 or more.
    ///   - limits: Time and instruction bounds. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    ///   - progress: Called after each step on the connection's thread. Keep it cheap.
    /// - Returns: The final progress: every page copied.
    @discardableResult
    public func backup(
        to path: String, pagesPerStep: Int = 256, limits: SQLiteOperationLimits? = nil,
        progress: (@Sendable (SQLiteBackupProgress) -> Void)? = nil
    ) async throws(SQLiteError) -> SQLiteBackupProgress {
        guard pagesPerStep >= 1 else { throw .invalidArgument("pagesPerStep must be at least 1") }
        try Self.requireNewFile(path)
        return try await observed(.backup) { (measure) async throws(SQLiteError) -> SQLiteBackupProgress in
        try await onReader(limits, &measure) { (core) throws(SQLiteError) -> SQLiteBackupProgress in
            try core.execInternal("BEGIN DEFERRED")
            do throws(SQLiteError) {
                // Start the read snapshot before the copy, so every step sees it.
                _ = try core.scalarInternal("SELECT count(*) FROM sqlite_schema")
                let result = try Self.copyPages(from: core, to: path, pagesPerStep: Int32(clamping: pagesPerStep),
                                                compact: false, progress: progress)
                try core.execFinishing("COMMIT")
                try Self.requireCreated(path)
                return result
            } catch {
                core.rollbackIfNeeded()
                Self.removeDatabaseFiles(path)
                throw error
            }
        }
        }
    }

    /// Writes a compacted copy of the database to a new file with `VACUUM INTO`.
    ///
    /// The copy is a consistent snapshot, without free pages. It runs on a reader
    /// connection, so writes continue meanwhile. The destination must not exist; a
    /// stopped or failed copy is removed.
    ///
    /// - Parameters:
    ///   - path: The new file.
    ///   - limits: Time and instruction bounds. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    public func vacuum(into path: String, limits: SQLiteOperationLimits? = nil) async throws(SQLiteError) {
        try Self.requireNewFile(path)
        try await observed(.vacuumInto) { (measure) async throws(SQLiteError) in
            try await vacuumUnobserved(into: path, limits: limits, &measure)
        }
    }

    private func vacuumUnobserved(
        into path: String, limits: SQLiteOperationLimits?, _ measure: inout SQLiteMeasure
    ) async throws(SQLiteError) {
        let body: @Sendable (SQLiteConnectionCore) throws(SQLiteError) -> Void = { (core) throws(SQLiteError) in
            do throws(SQLiteError) {
                // VACUUM INTO attaches the target and runs its own transaction:
                // SQLiteSwift's own SQL, so transaction control is allowed here.
                core.allowTransactionControl = true
                defer { core.allowTransactionControl = false }
                let (statement, _) = try core.prepare("VACUUM INTO ?", cached: false)
                defer { core.release(statement, isCached: false) }
                try core.bind([.text(path)], to: statement)
                let rc = sqlite3_step(statement)
                guard rc == SQLITE_DONE else { throw core.error(rc) }
                try core.checkStop()
            } catch {
                Self.removeDatabaseFiles(path)
                throw error
            }
        }
        guard case .file = configuration.storage else {
            // An in-memory connection would attach the target in memory too (SQLite
            // carries SQLITE_OPEN_MEMORY over), so nothing would reach the disk. Copy
            // the pages with the backup API instead, then compact the copy.
            try await onWriter(limits, &measure) { (core) throws(SQLiteError) in
                do throws(SQLiteError) {
                    _ = try Self.copyPages(from: core, to: path, pagesPerStep: 1024, compact: true, progress: nil)
                } catch {
                    Self.removeDatabaseFiles(path)
                    throw error
                }
            }
            try Self.requireCreated(path)
            return
        }
        // Readers are read-only, and SQLite attaches the target read-only too. A
        // short-lived read-write connection keeps the writer free meanwhile.
        guard !isClosing else { throw .closed }
        let token = try makeToken(limits)
        let connection = try SQLiteConnection(role: .maintenance, configuration: configuration)
        measure.acquired = .now
        do throws(SQLiteError) {
            try await connection.run(token: token) { (core) throws(SQLiteError) in
                try core.open()
                try core.execInternal("PRAGMA trusted_schema = OFF")
                try body(core)
            }
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            throw error
        }
        try Self.requireCreated(path)
    }

    // MARK: Integrity

    /// Runs `PRAGMA integrity_check`: a full check of every page, index and
    /// constraint. It reads the whole database; give it a deadline on large files.
    ///
    /// - Parameters:
    ///   - maxProblems: Stop after this many problems.
    ///   - limits: Time and instruction bounds. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    public func integrityCheck(
        maxProblems: Int = 100, limits: SQLiteOperationLimits? = nil
    ) async throws(SQLiteError) -> SQLiteIntegrityReport {
        try await check("integrity_check", .integrityCheck, maxProblems: maxProblems, limits: limits)
    }

    /// Runs `PRAGMA quick_check`: like ``integrityCheck(maxProblems:limits:)`` but
    /// without checking that indexes match their tables, so it is much faster.
    ///
    /// - Parameters:
    ///   - maxProblems: Stop after this many problems.
    ///   - limits: Time and instruction bounds. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    public func quickCheck(
        maxProblems: Int = 100, limits: SQLiteOperationLimits? = nil
    ) async throws(SQLiteError) -> SQLiteIntegrityReport {
        try await check("quick_check", .quickCheck, maxProblems: maxProblems, limits: limits)
    }

    private func check(
        _ pragma: String, _ kind: SQLiteOperation.Kind, maxProblems: Int, limits: SQLiteOperationLimits?
    ) async throws(SQLiteError) -> SQLiteIntegrityReport {
        guard maxProblems >= 1 else { throw .invalidArgument("maxProblems must be at least 1") }
        return try await observed(kind) { (measure) async throws(SQLiteError) -> SQLiteIntegrityReport in
            try await readUnobserved(limits: limits, measure: &measure) { (tx) throws(SQLiteError) -> SQLiteIntegrityReport in
                let rows = try tx.core.integrityRows("PRAGMA \(pragma)(\(maxProblems))")
                return SQLiteIntegrityReport(problems: rows == ["ok"] ? [] : rows)
            }
        }
    }

    // MARK: Explicit maintenance

    /// Runs `PRAGMA optimize`, which updates the query planner's statistics where
    /// they are likely stale. Cheap; SQLite recommends it before closing a
    /// long-lived connection and periodically on servers.
    ///
    /// - Parameter limits: Time and instruction bounds. `nil` uses
    ///   ``SQLiteConfiguration/operationLimits``.
    public func optimize(limits: SQLiteOperationLimits? = nil) async throws(SQLiteError) {
        try await observed(.optimize) { (measure) async throws(SQLiteError) in
            try await onWriter(limits, &measure) { (core) throws(SQLiteError) in try core.execInternal("PRAGMA optimize") }
        }
    }

    /// Returns up to `pages` free pages to the file system (`PRAGMA
    /// incremental_vacuum`). Only a database created with
    /// ``SQLiteAutoVacuum/incremental`` has pages to return; otherwise it does nothing.
    ///
    /// - Parameters:
    ///   - pages: How many pages to free; `nil` frees all.
    ///   - limits: Time and instruction bounds. `nil` uses
    ///     ``SQLiteConfiguration/operationLimits``.
    public func incrementalVacuum(pages: Int? = nil, limits: SQLiteOperationLimits? = nil) async throws(SQLiteError) {
        if let pages, pages < 1 { throw .invalidArgument("pages must be at least 1") }
        let sql = "PRAGMA incremental_vacuum(\(pages ?? 0))"
        try await observed(.incrementalVacuum) { (measure) async throws(SQLiteError) in
            try await onWriter(limits, &measure) { (core) throws(SQLiteError) in try core.execInternal(sql) }
        }
    }

    // MARK: Plumbing

    private func onReader<T: Sendable>(
        _ limits: SQLiteOperationLimits?, _ measure: inout SQLiteMeasure,
        _ body: @escaping @Sendable (SQLiteConnectionCore) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let token = try makeToken(limits)
        let (pool, connections) = readerPool.map { ($0, readers) } ?? (writerPool, [writer])
        let slot = try await pool.acquire(deadline: token.deadline)
        defer { pool.release(slot) }
        measure.acquired = .now
        return try await connections[slot].run(token: token, body)
    }

    private func onWriter<T: Sendable>(
        _ limits: SQLiteOperationLimits?, _ measure: inout SQLiteMeasure,
        _ body: @escaping @Sendable (SQLiteConnectionCore) throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let token = try makeToken(limits)
        let slot = try await writerPool.acquire(deadline: token.deadline)
        defer { writerPool.release(slot) }
        measure.acquired = .now
        return try await writer.run(token: token, body)
    }

    private static func requireNewFile(_ path: String) throws(SQLiteError) {
        guard !path.isEmpty, !path.hasPrefix(":"), !path.hasPrefix("file:") else {
            throw .invalidArgument("the destination must be a plain file path")
        }
        guard access(path, F_OK) != 0 else {
            throw .invalidArgument("the destination already exists; nothing is overwritten")
        }
    }

    /// A defense against silent no-ops: the operation must have produced the file.
    private static func requireCreated(_ path: String) throws(SQLiteError) {
        guard access(path, F_OK) == 0 else {
            throw .sqlite(code: .ioError, message: "the copy was not written to \(path)")
        }
    }

    private static func removeDatabaseFiles(_ path: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] { unlink(path + suffix) }
    }

    /// Copies every page of the core's main database into a new file at `path`.
    private static func copyPages(
        from core: SQLiteConnectionCore, to path: String, pagesPerStep: Int32, compact: Bool,
        progress: (@Sendable (SQLiteBackupProgress) -> Void)?
    ) throws(SQLiteError) -> SQLiteBackupProgress {
        let source = try core.handle()
        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXRESCODE
        let openCode = sqlite3_open_v2(path, &destination, flags, nil)
        guard openCode == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw .sqlite(code: SQLiteResultCode(rawValue: openCode), message: "cannot create the backup file")
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw .sqlite(code: SQLiteResultCode(rawValue: sqlite3_errcode(destination)),
                          message: String(cString: sqlite3_errmsg(destination)))
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        while true {
            let rc = sqlite3_backup_step(backup, pagesPerStep)
            let total = Int(sqlite3_backup_pagecount(backup))
            let state = SQLiteBackupProgress(copiedPages: total - Int(sqlite3_backup_remaining(backup)), totalPages: total)
            progress?(state)
            if rc == SQLITE_DONE {
                finished = true
                let finish = sqlite3_backup_finish(backup)
                guard finish == SQLITE_OK else {
                    throw .sqlite(code: SQLiteResultCode(rawValue: finish), message: String(cString: sqlite3_errmsg(destination)))
                }
                if compact {
                    let vacuum = sqlite3_exec(destination, "VACUUM", nil, nil, nil)
                    guard vacuum == SQLITE_OK else {
                        throw .sqlite(code: SQLiteResultCode(rawValue: vacuum), message: String(cString: sqlite3_errmsg(destination)))
                    }
                }
                return state
            }
            guard rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED else {
                throw .sqlite(code: SQLiteResultCode(rawValue: rc), message: String(cString: sqlite3_errmsg(destination)))
            }
            try core.checkStop()
            if rc != SQLITE_OK { sqlite3_sleep(5) }
        }
    }
}

extension SQLiteConnectionCore {
    /// The text rows of an integrity pragma.
    func integrityRows(_ sql: String) throws(SQLiteError) -> [String] {
        let db = try handle()
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw error(step) }
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
            try checkStop()
        }
    }
}
