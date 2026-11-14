// SPDX-License-Identifier: Apache-2.0

import Observation
import SQLiteSwift
import SQLiteSwiftModels

/// One record being edited in a ``SQLiteModelContext``.
///
/// Edit ``value`` directly; the context saves it with ``SQLiteModelContext/save()``.
/// The handle keeps what the edit is based on (``baseline``), the latest row known
/// to differ from it (``remote``), and a ``state``. It is observable, so views
/// update when any of these change.
@MainActor @Observable
public final class SQLiteModel<Record: SQLiteRecord> {
    /// Where a handle stands.
    ///
    /// The cases are complete; no case will be added.
    public enum State: Sendable, Hashable {
        /// The value equals the stored row it was read from.
        case clean
        /// There are local edits (or a new record, or a deletion) not yet saved.
        case dirty
        /// A save of the edits is running. Later edits are kept apart and stay
        /// unsaved after it.
        case saving
        /// The stored row changed or was deleted since the baseline. Resolve with
        /// ``useRemote()``, ``keepLocal()`` or ``discard()``.
        case conflicted
        /// The row is deleted, by this context or remotely. The handle is no longer
        /// managed.
        case deleted
        /// A save's commit outcome is unknown. Resolve with
        /// ``SQLiteModelContext/resolveIndeterminate()``.
        case indeterminate
    }

    /// The record's key. It can't change; a save of a value with another key throws.
    public let id: Record.ID

    /// The working value. Setting it is a local edit.
    public var value: Record {
        get { working }
        set {
            working = newValue
            editGeneration &+= 1
            if state == .clean { state = .dirty }
        }
    }

    /// The handle's state.
    public private(set) var state: State
    /// The stored row the local value is based on; `nil` for a record not yet inserted.
    public private(set) var baseline: SQLiteRecordSnapshot<Record>?
    /// The newer stored row found by a refresh or a conflicting save, if any.
    public private(set) var remote: SQLiteRecordSnapshot<Record>?
    /// Whether the row was found deleted by someone else.
    public private(set) var isDeletedRemotely = false
    /// Whether the next save deletes the row.
    public private(set) var isMarkedForDeletion = false

    /// Whether the value has edits the database doesn't have yet.
    public var hasUnsavedChanges: Bool {
        switch state {
        case .dirty, .conflicted, .indeterminate: true
        case .saving: editGeneration != savingGeneration
        case .clean, .deleted: false
        }
    }

    var working: Record
    /// Counts local edits only. Applying a stored row never changes it.
    @ObservationIgnored var editGeneration = 0
    @ObservationIgnored var savingGeneration = 0
    @ObservationIgnored weak var context: SQLiteModelContext?

    init(snapshot: SQLiteRecordSnapshot<Record>, context: SQLiteModelContext) {
        id = snapshot.value.id
        working = snapshot.value
        baseline = snapshot
        state = .clean
        self.context = context
    }

    init(new value: Record, context: SQLiteModelContext) {
        id = value.id
        working = value
        baseline = nil
        state = .dirty
        self.context = context
    }

    // MARK: Resolution

    /// Takes the stored row: the local edits are dropped. If the row was deleted
    /// remotely, the handle becomes ``State/deleted``.
    public func useRemote() throws(SQLiteError) {
        guard state == .conflicted else { throw .misuse("useRemote() needs a conflicted handle; it is \(state)") }
        takeRemote()
    }

    /// Keeps the local value and bases it on the stored row, so the next save
    /// updates that row, still conditionally on its version. A row deleted remotely
    /// can't be kept: that would recreate it.
    public func keepLocal() throws(SQLiteError) {
        guard state == .conflicted else { throw .misuse("keepLocal() needs a conflicted handle; it is \(state)") }
        guard let remote, !isDeletedRemotely else {
            throw .misuse("\(Record.self) \(id) was deleted remotely and can't be kept; use discard() or useRemote()")
        }
        baseline = remote
        self.remote = nil
        state = .dirty
    }

    /// Drops the local edits. A conflicted handle takes the stored row; a record that
    /// was never inserted leaves the context.
    public func discard() throws(SQLiteError) {
        switch state {
        case .clean, .deleted:
            return
        case .saving, .indeterminate:
            throw .misuse("discard() can't run while a save of \(Record.self) \(id) is \(state)")
        case .conflicted:
            takeRemote()
        case .dirty:
            isMarkedForDeletion = false
            if let baseline {
                working = baseline.value
                state = .clean
            } else {
                markDeleted()
            }
        }
    }

    private func takeRemote() {
        isMarkedForDeletion = false
        if isDeletedRemotely || remote == nil {
            markDeleted()
            return
        }
        if let remote {
            working = remote.value
            baseline = remote
        }
        remote = nil
        state = .clean
    }

    func markForDeletion() throws(SQLiteError) {
        switch state {
        case .clean, .dirty:
            if baseline == nil {
                markDeleted()
            } else {
                isMarkedForDeletion = true
                state = .dirty
            }
        default:
            throw .misuse("\(Record.self) \(id) can't be deleted while it is \(state)")
        }
    }

    func markDeleted() {
        state = .deleted
        remote = nil
        context?.unregister(Record.self, id: id)
    }

    // MARK: Remote rows

    /// Applies a stored row (or its absence) read after the handle was loaded.
    func applyRemote(_ snapshot: SQLiteRecordSnapshot<Record>?) {
        switch state {
        case .clean:
            guard let snapshot else {
                isDeletedRemotely = true
                markDeleted()
                return
            }
            if snapshot != baseline {
                working = snapshot.value
                baseline = snapshot
            }
        case .dirty:
            guard let baseline else {
                // A new record whose key now exists.
                if let snapshot {
                    remote = snapshot
                    state = .conflicted
                }
                return
            }
            if let snapshot {
                if snapshot.version != baseline.version {
                    remote = snapshot
                    state = .conflicted
                } else if snapshot != baseline {
                    self.baseline = snapshot
                }
            } else {
                isDeletedRemotely = true
                state = .conflicted
            }
        case .conflicted:
            remote = snapshot
            isDeletedRemotely = snapshot == nil
        case .saving, .indeterminate, .deleted:
            // The save or its resolution establishes the truth.
            break
        }
    }

    // MARK: Saving

    func capture() throws(SQLiteError) -> CapturedWrite? {
        guard state == .dirty else { return nil }
        guard working.id == id else {
            throw .invalidArgument("the key of a managed \(Record.self) can't change (from \(id) to \(working.id))")
        }
        let generation = editGeneration
        let value = working
        let write: SQLiteRecordWrite
        let known: SQLiteRecordSnapshot<Record>?
        if isMarkedForDeletion, let baseline {
            write = .delete(Record.self, id: id, expecting: baseline.version)
            known = nil
        } else if let baseline {
            write = .update(value, expecting: baseline.version)
            known = SQLiteRecordSnapshot(
                value: value,
                version: try SQLiteRecordVersion(
                    revision: baseline.version.revision == .max ? .max : baseline.version.revision + 1,
                    incarnation: baseline.version.incarnation))
        } else {
            let incarnation = SQLiteRecordVersion.newIncarnation()
            write = .save(value, expecting: .absent, incarnation: incarnation)
            known = SQLiteRecordSnapshot(value: value, version: try SQLiteRecordVersion(revision: 1, incarnation: incarnation))
        }
        state = .saving
        savingGeneration = generation
        return CapturedWrite(
            write: write,
            idDescription: String(describing: id),
            committed: { report in
                if let outcome = report.outcome(as: Record.self) {
                    self.didCommit(outcome.snapshot, generation: generation)
                }
            },
            committedWithoutReport: { self.didCommit(known, generation: generation) },
            notCommitted: { self.state = .dirty },
            conflicted: { report in
                switch report.outcome(as: Record.self) {
                case .conflict(let current):
                    self.remote = current
                    self.isDeletedRemotely = false
                case .missing:
                    self.remote = nil
                    self.isDeletedRemotely = true
                default:
                    break
                }
                self.state = .conflicted
            },
            indeterminate: { self.state = .indeterminate },
            refresh: { (context) throws(SQLiteError) in try await context.refresh(self) })
    }

    /// `snapshot` is the stored row after the save, or `nil` for a deletion.
    private func didCommit(_ snapshot: SQLiteRecordSnapshot<Record>?, generation: Int) {
        guard let snapshot else {
            markDeleted()
            return
        }
        baseline = snapshot
        remote = nil
        isMarkedForDeletion = false
        if editGeneration == generation {
            working = snapshot.value
            state = .clean
        } else {
            state = .dirty
        }
    }
}

/// One handle's part of a save, with what to do for each outcome.
@MainActor
struct CapturedWrite {
    let write: SQLiteRecordWrite
    let idDescription: String
    let committed: (SQLiteRecordWriteReport) -> Void
    /// A commit learned by resolving an unknown outcome: the version is known
    /// exactly, since an insert's incarnation is chosen before the write and an
    /// update only applies at the expected revision.
    let committedWithoutReport: () -> Void
    let notCommitted: () -> Void
    let conflicted: (SQLiteRecordWriteReport) -> Void
    let indeterminate: () -> Void
    let refresh: (SQLiteModelContext) async throws(SQLiteError) -> Void
}
