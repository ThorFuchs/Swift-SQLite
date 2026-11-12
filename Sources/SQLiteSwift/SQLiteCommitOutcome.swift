// SPDX-License-Identifier: Apache-2.0

/// What happened to a write transaction, as far as SQLiteSwift knows.
///
/// The three cases are complete: a write either committed, did not commit, or its
/// `COMMIT` failed in a way that leaves the outcome unknown. No case will be added.
///
/// Returned by ``SQLiteDatabase/writeReportingOutcome(limits:_:)``.
public enum SQLiteCommitOutcome<Value: Sendable>: Sendable {
    /// `COMMIT` succeeded. The value is what the closure returned.
    case committed(Value)
    /// The transaction was not committed (the closure threw, the operation stopped,
    /// or `COMMIT` failed while the transaction was still open and it was rolled back).
    case notCommitted(SQLiteError)
    /// `COMMIT` was issued and did not report success, and the transaction ended. It
    /// may or may not be durable. The error has the code
    /// ``SQLiteError/Code/commitOutcomeUnknown``; its ``SQLiteError/underlying`` is
    /// what `COMMIT` reported. Decide with ``SQLiteDatabase/resolveCommit(limits:_:)``.
    case unknown(SQLiteError)

    /// The committed value, or `nil`.
    public var value: Value? {
        if case .committed(let value) = self { return value }
        return nil
    }

    /// The error of a write that did not commit or whose outcome is unknown.
    public var error: SQLiteError? {
        switch self {
        case .committed: nil
        case .notCommitted(let error), .unknown(let error): error
        }
    }
}

extension SQLiteCommitOutcome: Equatable where Value: Equatable {}
extension SQLiteCommitOutcome: Hashable where Value: Hashable {}

extension SQLiteDatabase {
    /// Runs `body` in a write transaction and reports the commit outcome as a value
    /// instead of throwing.
    ///
    /// It behaves like ``write(limits:_:)``. Use it where the three outcomes need
    /// different handling, for example to record an exactly-once input:
    ///
    /// ```swift
    /// switch await database.writeReportingOutcome({ tx throws(SQLiteError) in
    ///     try tx.execute("INSERT INTO inputs (key, body) VALUES (?, ?)", [.text(key), .blob(body)])
    /// }) {
    /// case .committed: acknowledge()
    /// case .notCommitted(let error): reject(error)
    /// case .unknown:
    ///     let stored = try await database.resolveCommit { tx throws(SQLiteError) in
    ///         try tx.queryOne("SELECT 1 FROM inputs WHERE key = ?", [.text(key)]) != nil
    ///     }
    ///     stored ? acknowledge() : retry()
    /// }
    /// ```
    public func writeReportingOutcome<T: Sendable>(
        limits: SQLiteOperationLimits? = nil,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T
    ) async -> SQLiteCommitOutcome<T> {
        do throws(SQLiteError) {
            return .committed(try await write(limits: limits, body))
        } catch {
            return error.code == .commitOutcomeUnknown ? .unknown(error) : .notCommitted(error)
        }
    }

    /// Decides an unknown commit outcome with a fresh read.
    ///
    /// Write an idempotency key (or another marker) in the same transaction as the
    /// data, then let `probe` look for it. For a file database the probe runs on a
    /// new read-only connection that has never seen the failed transaction; it sees
    /// exactly what is durable in the file. For an in-memory database it runs as an
    /// ordinary ``read(limits:_:)``.
    ///
    /// Call it only after the original write call has returned. SQLiteSwift never
    /// runs two writes at once, so the answer cannot change afterwards unless your
    /// own code writes again.
    ///
    /// - Returns: What `probe` returned: whether the transaction's marker is present.
    public func resolveCommit(
        limits: SQLiteOperationLimits? = nil,
        _ probe: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> Bool
    ) async throws(SQLiteError) -> Bool {
        guard case .file = configuration.storage else {
            return try await read(limits: limits, probe)
        }
        guard !isClosing else { throw .closed }
        let limits = limits ?? configuration.operationLimits
        try limits.validate()
        let token = SQLiteJobToken(
            deadline: limits.timeout.map { ContinuousClock.now + $0 },
            maxInstructions: limits.maxInstructions)
        let connection = try SQLiteConnection(role: .probe, configuration: configuration)
        do throws(SQLiteError) {
            let found = try await connection.run(token: token) { (core) throws(SQLiteError) -> Bool in
                try core.open()
                try core.configureReader()
                try core.execInternal("BEGIN DEFERRED")
                let transaction = SQLiteTransaction(core: core, kind: .read)
                defer { transaction.invalidate() }
                do throws(SQLiteError) {
                    let found = try probe(transaction)
                    try core.execFinishing("COMMIT")
                    return found
                } catch {
                    core.rollbackIfNeeded()
                    throw error
                }
            }
            await connection.shutdown()
            return found
        } catch {
            await connection.shutdown()
            throw error
        }
    }
}
