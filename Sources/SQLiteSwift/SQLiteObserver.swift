// SPDX-License-Identifier: Apache-2.0

/// One database operation, as an observer sees it.
public struct SQLiteOperation: Sendable, Hashable, CustomStringConvertible {
    /// What kind of operation it is. New kinds can be added in minor releases, so
    /// a `switch` over kinds needs a `default` branch.
    public struct Kind: Sendable, Hashable, CustomStringConvertible {
        /// A stable, lowercase name such as `"write"`, suitable as a metric dimension.
        public let name: String

        init(_ name: String) { self.name = name }

        public var description: String { name }

        public static let read = Kind("read")
        public static let write = Kind("write")
        public static let resolveCommit = Kind("resolve_commit")
        public static let checkpoint = Kind("checkpoint")
        public static let backup = Kind("backup")
        public static let vacuumInto = Kind("vacuum_into")
        public static let integrityCheck = Kind("integrity_check")
        public static let quickCheck = Kind("quick_check")
        public static let optimize = Kind("optimize")
        public static let incrementalVacuum = Kind("incremental_vacuum")
    }

    public let kind: Kind
    /// The database file, or `":memory:"`.
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    public var description: String { "\(kind) \(path)" }
}

/// What an observed operation did and how long it took.
public struct SQLiteOperationReport: Sendable {
    /// How an operation ended.
    ///
    /// The cases are complete; no case will be added.
    public enum Outcome: Sendable {
        /// It finished; a write committed.
        case succeeded
        /// A `writeOrRollback` closure chose to roll back. Nothing was committed.
        case rolledBack
        /// It threw. `commitOutcomeUnknown` is among these; check the error's code.
        case failed(SQLiteError)
    }

    public let operation: SQLiteOperation
    /// The time spent waiting for a connection (and the writer lock) before the work
    /// started. Long waits mean contention.
    public let connectionWait: Duration
    /// The whole operation, including the wait.
    public let duration: Duration
    public let outcome: Outcome

    public init(operation: SQLiteOperation, connectionWait: Duration, duration: Duration, outcome: Outcome) {
        self.operation = operation
        self.connectionWait = connectionWait
        self.duration = duration
        self.outcome = outcome
    }
}

/// Watches every operation of a database, for metrics, tracing and logs.
///
/// Set it with ``SQLiteConfiguration/observer``. Both methods run **on the task that
/// called the operation**, before and after it, never on a connection's thread. So
/// task-local values (a tracing context, a task-local logger) are available, and a
/// span can enclose the whole operation:
///
/// ```swift
/// struct Timing: SQLiteObserver {
///     func operationDidFinish(_ report: SQLiteOperationReport, context: Void) {
///         print(report.operation.kind, report.duration)
///     }
/// }
/// ```
///
/// Keep both methods cheap; they run on every operation. They must not call back
/// into the same database.
public protocol SQLiteObserver: Sendable {
    /// Whatever the observer needs to carry from start to finish (a span, a start
    /// time). `Void` if nothing.
    associatedtype Context: Sendable = Void

    /// Called before the operation waits for a connection.
    func operationWillStart(_ operation: SQLiteOperation) -> Context

    /// Called after the operation finished, with the value `operationWillStart`
    /// returned.
    func operationDidFinish(_ report: SQLiteOperationReport, context: Context)
}

extension SQLiteObserver where Context == Void {
    public func operationWillStart(_ operation: SQLiteOperation) {}
}

/// Timing collected while an operation runs, filled in by the operation itself.
struct SQLiteMeasure: Sendable {
    var acquired: ContinuousClock.Instant?
    var rolledBack = false
}

extension SQLiteDatabase {
    /// Runs `body` and reports it to the configured observer, if any.
    func observed<T: Sendable>(
        _ kind: SQLiteOperation.Kind,
        _ body: (inout SQLiteMeasure) async throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        guard let observer = configuration.observer else {
            var measure = SQLiteMeasure()
            return try await body(&measure)
        }
        return try await observed(by: observer, kind, body)
    }

    private func observed<O: SQLiteObserver, T: Sendable>(
        by observer: O, _ kind: SQLiteOperation.Kind,
        _ body: (inout SQLiteMeasure) async throws(SQLiteError) -> T
    ) async throws(SQLiteError) -> T {
        let operation = SQLiteOperation(kind: kind, path: configuration.path)
        let context = observer.operationWillStart(operation)
        let start = ContinuousClock.now
        var measure = SQLiteMeasure()
        func report(_ outcome: SQLiteOperationReport.Outcome) {
            let end = ContinuousClock.now
            observer.operationDidFinish(
                SQLiteOperationReport(
                    operation: operation, connectionWait: (measure.acquired ?? end) - start,
                    duration: end - start, outcome: outcome),
                context: context)
        }
        do throws(SQLiteError) {
            let value = try await body(&measure)
            report(measure.rolledBack ? .rolledBack : .succeeded)
            return value
        } catch {
            report(.failed(error))
            throw error
        }
    }
}

extension SQLiteDatabase {
    /// Makes the next `COMMIT` on the writer fail after its transaction ended, so the
    /// write reports ``SQLiteError/Code/commitOutcomeUnknown`` (nothing is durable).
    /// For `SQLiteSwiftTesting`'s fault injection only.
    package func armUnknownCommitOutcomeForTesting() async throws(SQLiteError) {
        let slot = try await writerPool.acquire()
        defer { writerPool.release(slot) }
        try await writer.run { (core) throws(SQLiteError) in core.failNextCommitForTesting = true }
    }
}
