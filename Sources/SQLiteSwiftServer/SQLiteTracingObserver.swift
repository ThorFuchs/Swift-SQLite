// SPDX-License-Identifier: Apache-2.0

#if Tracing
import SQLiteSwift
import Tracing

/// Wraps every database operation in a client span of swift-distributed-tracing.
///
/// The span starts on the calling task, so it becomes a child of the task's current
/// span (`InstrumentationContext.current`), and ends when the operation finishes. It
/// is named `sqlite.<operation>` (for example `sqlite.write`) and carries the
/// OpenTelemetry database attributes `db.system.name` and `db.operation.name`, plus
/// `db.sqlite.connection_wait_ms`. A failure is recorded as an error with
/// `db.response.status_code` set to the `SQLiteError.Code` name, and the span's status
/// becomes `.error`.
///
/// For the globally bootstrapped tracer use ``SQLiteTracing/observer()``.
public struct SQLiteTracingObserver<T: Tracer>: SQLiteObserver {
    public typealias Context = T.Span
    public let tracer: T

    public init(tracer: T) {
        self.tracer = tracer
    }

    public func operationWillStart(_ operation: SQLiteOperation) -> T.Span {
        let span = tracer.startSpan("sqlite.\(operation.kind.name)", ofKind: .client)
        span.attributes["db.system.name"] = "sqlite"
        span.attributes["db.operation.name"] = operation.kind.name
        return span
    }

    public func operationDidFinish(_ report: SQLiteOperationReport, context span: T.Span) {
        span.attributes["db.sqlite.connection_wait_ms"] = report.connectionWait.milliseconds
        switch report.outcome {
        case .succeeded:
            break
        case .rolledBack:
            span.attributes["db.sqlite.rolled_back"] = true
        case .failed(let error):
            span.attributes["db.response.status_code"] = error.code.name
            span.recordError(error)
            span.setStatus(SpanStatus(code: .error, message: error.code.name))
        }
        span.end()
    }
}

/// The tracing bridge for the tracer bootstrapped in `InstrumentationSystem`.
public enum SQLiteTracing {
    /// An observer that uses `InstrumentationSystem.tracer`. Create it after
    /// bootstrapping the instrumentation system.
    public static func observer() -> any SQLiteObserver {
        func make<T: Tracer>(_ tracer: T) -> any SQLiteObserver { SQLiteTracingObserver(tracer: tracer) }
        return make(InstrumentationSystem.tracer)
    }
}
#endif
