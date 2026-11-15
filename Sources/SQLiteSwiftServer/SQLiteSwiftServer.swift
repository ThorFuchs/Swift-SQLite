// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

// Bridges from SQLiteSwift to the Swift server ecosystem. Each bridge is compiled
// only when its package trait is enabled, so the module is empty, and the
// dependency graph stays empty, unless a consumer asks for one:
//
//     .package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.1.0",
//              traits: ["Metrics", "Tracing", "Logging", "ServiceLifecycle"])
//
// - Metrics:          SQLiteMetricsObserver (swift-metrics)
// - Tracing:          SQLiteTracingObserver (swift-distributed-tracing)
// - Logging:          SQLiteLoggingObserver (swift-log)
// - ServiceLifecycle: SQLiteDatabaseService (swift-service-lifecycle)
//
// Combine observers with SQLiteObservers(metrics, tracing, logging).

extension Duration {
    /// Whole nanoseconds, saturating.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? .max : whole + attoseconds / 1_000_000_000
    }

    /// Milliseconds as a Double, for logs and span attributes.
    var milliseconds: Double { Double(nanoseconds) / 1_000_000 }
}

extension SQLiteOperationReport.Outcome {
    /// `succeeded`, `rolled_back` or `failed`: a low-cardinality label.
    var label: String {
        switch self {
        case .succeeded: "succeeded"
        case .rolledBack: "rolled_back"
        case .failed: "failed"
        }
    }

    var error: SQLiteError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
