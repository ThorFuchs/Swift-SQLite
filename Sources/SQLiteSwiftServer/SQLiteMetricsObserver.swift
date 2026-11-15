// SPDX-License-Identifier: Apache-2.0

#if Metrics
import Metrics
import SQLiteSwift

/// Records every database operation in swift-metrics.
///
/// | Metric | Type | Dimensions |
/// | --- | --- | --- |
/// | `<prefix>_operation_duration` | Timer | `operation`, `outcome`, `database` |
/// | `<prefix>_connection_wait` | Timer | `operation`, `database` |
/// | `<prefix>_operation_errors` | Counter | `operation`, `code`, `database` |
///
/// `operation` is `SQLiteOperation.Kind.name` (for example `write`),
/// `outcome` is `succeeded`, `rolled_back` or `failed`, `code` is the error's
/// `SQLiteError.Code` name. `database` appears only if you name the database; the
/// file path is never used, so the cardinality stays bounded.
public struct SQLiteMetricsObserver: SQLiteObserver {
    public let prefix: String
    public let database: String?
    let factory: any MetricsFactory

    /// - Parameters:
    ///   - prefix: The start of every metric label.
    ///   - database: A short, stable name for this database, added as a dimension.
    ///   - factory: The metrics backend. Default: the one bootstrapped in `MetricsSystem`.
    public init(prefix: String = "sqlite", database: String? = nil, factory: any MetricsFactory = MetricsSystem.factory) {
        self.prefix = prefix
        self.database = database
        self.factory = factory
    }

    public func operationDidFinish(_ report: SQLiteOperationReport, context: Void) {
        var base = [("operation", report.operation.kind.name)]
        if let database { base.append(("database", database)) }
        Timer(label: "\(prefix)_operation_duration", dimensions: base + [("outcome", report.outcome.label)], factory: factory)
            .recordNanoseconds(report.duration.nanoseconds)
        Timer(label: "\(prefix)_connection_wait", dimensions: base, factory: factory)
            .recordNanoseconds(report.connectionWait.nanoseconds)
        if let error = report.outcome.error {
            Counter(label: "\(prefix)_operation_errors", dimensions: base + [("code", error.code.name)], factory: factory)
                .increment()
        }
    }
}
#endif
