// SPDX-License-Identifier: Apache-2.0

#if Logging
import Logging
import SQLiteSwift

/// Logs database operations with swift-log.
///
/// - A failure is logged at `.warning` when it is a stop the caller asked for or can
///   retry (`busy`, `deadlineExceeded`, `instructionLimitExceeded`, `interrupted`)
///   and at `.error` otherwise, `commitOutcomeUnknown` included.
/// - An operation slower than the threshold is logged at `.notice`.
/// - Every other operation is logged at `.trace`.
///
/// Metadata: `sqlite.operation`, `sqlite.outcome`, `sqlite.duration_ms`,
/// `sqlite.wait_ms` and, for failures, `sqlite.error`.
public struct SQLiteLoggingObserver: SQLiteObserver {
    public let logger: Logger?
    public let slowOperationThreshold: Duration?

    /// - Parameters:
    ///   - logger: The logger. `nil` uses the calling task's `Logger.current`.
    ///   - slowOperationThreshold: Operations at least this long are logged at
    ///     `.notice`. `nil` turns that off.
    public init(logger: Logger? = nil, slowOperationThreshold: Duration? = .milliseconds(500)) {
        self.logger = logger
        self.slowOperationThreshold = slowOperationThreshold
    }

    private static let retryable: Set<SQLiteError.Code> = [.busy, .deadlineExceeded, .instructionLimitExceeded, .interrupted]

    public func operationDidFinish(_ report: SQLiteOperationReport, context: Void) {
        let logger = self.logger ?? Logger.current
        let kind = report.operation.kind.name
        var metadata: Logger.Metadata = [
            "sqlite.operation": .string(kind),
            "sqlite.outcome": .string(report.outcome.label),
            "sqlite.duration_ms": .stringConvertible(report.duration.milliseconds),
            "sqlite.wait_ms": .stringConvertible(report.connectionWait.milliseconds),
        ]
        if let error = report.outcome.error {
            metadata["sqlite.error"] = .string(error.code.name)
            let level: Logger.Level = Self.retryable.contains(error.code) ? .warning : .error
            logger.log(level: level, "SQLite \(kind) failed: \(error)", metadata: metadata)
        } else if let threshold = slowOperationThreshold, report.duration >= threshold {
            logger.notice("Slow SQLite \(kind)", metadata: metadata)
        } else {
            logger.trace("SQLite \(kind)", metadata: metadata)
        }
    }
}
#endif
