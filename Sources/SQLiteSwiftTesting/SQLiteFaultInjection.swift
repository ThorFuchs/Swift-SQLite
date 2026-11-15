// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// A failure ``SQLiteSwift/SQLiteDatabase/injectFault(_:)`` makes happen, so a store
/// can test how it handles it.
///
/// New faults can be added in minor releases.
public struct SQLiteFault: Sendable, Hashable, CustomStringConvertible {
    let name: String

    /// The next committing write throws `commitOutcomeUnknown`: its `COMMIT` fails
    /// after the transaction ended. Nothing of that write is durable, so
    /// `resolveCommit` finds no trace of it. Use it to test the resolution path.
    public static let commitOutcomeUnknown = SQLiteFault(name: "commitOutcomeUnknown")

    public var description: String { name }
}

extension SQLiteDatabase {
    /// Arms `fault` for this database. For tests only.
    ///
    /// ```swift
    /// try await database.injectFault(.commitOutcomeUnknown)
    /// let outcome = await database.writeReportingOutcome { tx throws(SQLiteError) in … }
    /// // outcome is .unknown; resolveCommit finds nothing
    /// ```
    ///
    /// A fault fires once, at the next operation it applies to (for
    /// ``SQLiteFault/commitOutcomeUnknown``: the next write that commits).
    public func injectFault(_ fault: SQLiteFault) async throws(SQLiteError) {
        switch fault {
        case .commitOutcomeUnknown: try await armUnknownCommitOutcomeForTesting()
        default: throw .invalidArgument("unknown fault \(fault)")
        }
    }
}
