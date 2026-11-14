// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// What a managed write expects to find before it changes anything.
///
/// The cases are complete; no case will be added.
public enum SQLiteWriteExpectation: Sendable, Hashable {
    /// No row has the record's key.
    case absent
    /// The row has exactly this version: the same revision and the same incarnation.
    case version(SQLiteRecordVersion)
}

/// The domain result of one managed write.
///
/// A conflict is a value, not an error, so callers decide what it means. Lock
/// contention, deadlines, cancellation, constraint violations and
/// `SQLiteError.Code.commitOutcomeUnknown` stay errors and are never folded into an
/// outcome.
///
/// The cases are complete; no case will be added.
public enum SQLiteRecordWriteOutcome<Record: SQLiteRecord>: Sendable {
    /// The record was inserted. The snapshot is the row as stored, at revision 1 with
    /// a new incarnation.
    case inserted(SQLiteRecordSnapshot<Record>)
    /// The record was updated. The snapshot is the row as stored, one revision on.
    case updated(SQLiteRecordSnapshot<Record>)
    /// The row was deleted.
    case deleted
    /// A row with the key exists but doesn't match the expectation: it was expected to
    /// be absent, or it has another revision or incarnation. `current` is that row.
    case conflict(current: SQLiteRecordSnapshot<Record>)
    /// A version was expected but no row has the key.
    case missing

    /// Whether the write changed the row (inserted, updated or deleted).
    public var isApplied: Bool {
        switch self {
        case .inserted, .updated, .deleted: true
        case .conflict, .missing: false
        }
    }

    /// The snapshot the write produced or found, if any.
    public var snapshot: SQLiteRecordSnapshot<Record>? {
        switch self {
        case .inserted(let s), .updated(let s), .conflict(let s): s
        case .deleted, .missing: nil
        }
    }
}

extension SQLiteRecordWriteOutcome: Equatable {}
