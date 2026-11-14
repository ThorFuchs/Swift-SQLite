// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift
import SQLiteSwiftModels

/// The result of ``SQLiteModelContext/save()``.
///
/// The cases are complete; no case will be added.
public enum SQLiteSaveResult: Sendable, Hashable {
    /// Every captured change committed. `count` is how many handles were saved (0
    /// if there was nothing to save).
    case saved(count: Int)
    /// One change conflicted, so the whole save was rolled back. That handle is now
    /// ``SQLiteModel/State/conflicted``; the others are back to
    /// ``SQLiteModel/State/dirty`` and are not blamed.
    case conflict(SQLiteSaveConflict)
}

/// The change that stopped a save.
public struct SQLiteSaveConflict: Sendable, Hashable {
    /// The table of the conflicting record.
    public let table: String
    /// The record's key, as text.
    public let id: String
    /// What the save found instead of the expected row.
    public let found: SQLiteRecordWriteReport.Summary
}

/// How ``SQLiteModelContext/resolveIndeterminate()`` decided an unknown save.
///
/// The cases are complete; no case will be added.
public enum SQLiteSaveResolution: Sendable, Hashable {
    /// The save committed. Its handles moved on as after an ordinary commit.
    case committed
    /// The save did not commit. Its handles are dirty again, with their edits.
    case notCommitted
}

/// A main-actor editing context over a database.
///
/// It loads records into ``SQLiteModel`` handles, one handle per record, and saves
/// their edits together:
///
/// ```swift
/// let context = SQLiteModelContext(store: store)
/// if let article = try await context.find(Article.self, id: "a1") {
///     article.value.title = "New title"
///     try await context.save()
/// }
/// ```
///
/// A context belongs to one place in an app, such as a window; there is no global
/// one. Server code should use transactions and `SQLiteDatabase.writeRecords(_:limits:)`
/// directly. Saves go through the store, so its change stream reports them with the
/// context's ``origin``.
///
/// Saves are conditional and atomic. A save never overwrites a row that changed
/// since its handle read it; it reports a conflict and keeps every edit. Saves run
/// one after another: a second `save()` waits for the first.
@MainActor
public final class SQLiteModelContext {
    /// The store the context saves through.
    public let store: SQLiteModelStore
    /// The database the context reads from.
    public var database: SQLiteDatabase { store.database }
    /// The origin of this context's saves in the store's change stream.
    public let origin = SQLiteChangeOrigin()

    private struct Key: Hashable {
        let type: ObjectIdentifier
        let id: AnyHashable
    }

    private var handles: [Key: AnyObject] = [:]
    /// Per table, per record type: the key of a change, if it decodes.
    private var decoders: [String: [ObjectIdentifier: (SQLiteRecordChange) -> AnyHashable?]] = [:]
    private var order: [Key] = []
    private var saveInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Markers of committed saves, deleted by the next save.
    private var committedMarkers: [[UInt8]] = []
    private var pending: PendingSave?

    private struct PendingSave {
        let marker: [UInt8]
        let deletedMarkers: [[UInt8]]
        let captures: [CapturedWrite]
    }

    // Test seams (internal; reached with `@testable import`).
    /// Awaited after the edits are captured and before the write starts.
    var beforeWriteForTesting: (@MainActor () async -> Void)?
    /// Runs inside the save's transaction, after the writes.
    var inTransactionForTesting: (@Sendable (SQLiteTransaction) throws(SQLiteError) -> Void)?
    /// Reports the next committed save as `commitOutcomeUnknown`.
    var reportNextCommitAsUnknownForTesting = false

    public init(store: SQLiteModelStore) {
        self.store = store
    }

    /// Whether a save's commit outcome is unknown. While it is, ``save()`` throws;
    /// call ``resolveIndeterminate()``.
    public var hasIndeterminateSave: Bool { pending != nil }

    // MARK: Handles

    /// The handle for the record with key `id`, loading it if needed, or `nil` if no
    /// row has the key.
    ///
    /// Every call for the same record returns the same handle, also when two calls
    /// run at once. A handle already in the context is returned as it is; use
    /// ``refresh(_:)`` to read the stored row again.
    public func find<Record: SQLiteRecord>(
        _ type: Record.Type, id: Record.ID
    ) async throws(SQLiteError) -> SQLiteModel<Record>? {
        let key = Key(type: ObjectIdentifier(Record.self), id: AnyHashable(id))
        if let existing = handles[key] as? SQLiteModel<Record> { return existing }
        let snapshot = try await database.read { (tx) throws(SQLiteError) in try tx.fetch(Record.self, id: id) }
        // Another find may have registered the handle while this one was reading.
        if let existing = handles[key] as? SQLiteModel<Record> {
            existing.applyRemote(snapshot)
            return existing.state == .deleted ? nil : existing
        }
        guard let snapshot else { return nil }
        let model = SQLiteModel(snapshot: snapshot, context: self)
        register(model, key: key)
        return model
    }

    /// A handle for a new record, inserted by the next save.
    ///
    /// Throws `SQLiteError.Code.misuse` if the context already has a handle with
    /// this key. If the database has a row with the key, the save reports a conflict.
    public func insert<Record: SQLiteRecord>(_ value: Record) throws(SQLiteError) -> SQLiteModel<Record> {
        let key = Key(type: ObjectIdentifier(Record.self), id: AnyHashable(value.id))
        guard handles[key] == nil else {
            throw .misuse("the context already has \(Record.self) \(value.id)")
        }
        let model = SQLiteModel(new: value, context: self)
        register(model, key: key)
        return model
    }

    /// Marks the record for deletion by the next save. A record that was never
    /// inserted just leaves the context.
    public func delete<Record: SQLiteRecord>(_ model: SQLiteModel<Record>) throws(SQLiteError) {
        try model.markForDeletion()
    }

    /// Reads the stored row again and applies it.
    ///
    /// - A clean handle takes the row, or becomes ``SQLiteModel/State/deleted`` if it
    ///   is gone.
    /// - A dirty handle keeps its edits; if the row changed or is gone, it becomes
    ///   ``SQLiteModel/State/conflicted``.
    /// - A handle being saved, or with an unknown save, is left alone.
    public func refresh<Record: SQLiteRecord>(_ model: SQLiteModel<Record>) async throws(SQLiteError) {
        try await refresh([model.remoteRead()])
    }

    /// Reads the rows of `reads` in one read transaction and applies them.
    private func refresh(_ reads: [RemoteRead]) async throws(SQLiteError) {
        guard !reads.isEmpty else { return }
        let fetches = reads.map(\.fetch)
        let rows = try await database.read { (tx) throws(SQLiteError) -> [any Sendable] in
            var rows: [any Sendable] = []
            for fetch in fetches { rows.append(try fetch(tx)) }
            return rows
        }
        for (read, row) in zip(reads, rows) { read.apply(row) }
    }

    // MARK: Observing changes

    /// Keeps the context's handles up to date with the store's committed changes
    /// until the calling task is cancelled.
    ///
    /// Run it for as long as the context is shown, for example in a SwiftUI
    /// `.task { try? await context.observeChanges() }`. For every batch saved
    /// through the store by someone else (another context, `writeRecords`), the
    /// handles of the changed records read their row again:
    ///
    /// - a clean handle takes the new value, or becomes ``SQLiteModel/State/deleted``
    ///   and leaves the context if the row was deleted;
    /// - a dirty handle keeps its draft and becomes ``SQLiteModel/State/conflicted``;
    /// - a handle being saved is left alone.
    ///
    /// If the stream asks for a resync (a full buffer or an unknown commit
    /// elsewhere), every handle is read again and observation goes on. Writes that
    /// don't go through the store are not seen until a refresh.
    public func observeChanges(bufferSize: Int = 1024) async throws(SQLiteError) {
        while !Task.isCancelled {
            let (_, changes) = try await store.subscribe(bufferSize: bufferSize) { (_) throws(SQLiteError) in () }
            // Rows committed before the subscription started are caught here.
            try await refresh(order.compactMap { (handles[$0] as? any ManagedModel)?.makeRemoteRead() })
            observationProgressed()
            for await event in changes {
                switch event {
                case .committed(let change):
                    if change.origin != origin { try await apply(change) }
                    lastAppliedSequence = change.sequence
                case .resyncRequired:
                    resyncCount += 1
                }
                observationProgressed()
            }
        }
    }

    private func apply(_ change: SQLiteCommittedChange) async throws(SQLiteError) {
        var reads: [RemoteRead] = []
        for record in change.changes {
            guard let types = decoders[record.table] else { continue }
            for (type, decode) in types {
                guard let id = decode(record), let model = handles[Key(type: type, id: id)] as? any ManagedModel else {
                    continue
                }
                if record.kind != .deleted, let version = record.version, model.knownVersion == version {
                    continue  // already known
                }
                reads.append(model.makeRemoteRead())
            }
        }
        try await refresh(reads)
    }

    // Observation progress, for tests.
    var lastAppliedSequence: Int64 = 0
    var resyncCount = 0
    private var progressWaiters: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until `condition` holds after an observation step.
    func waitForObservationForTesting(_ condition: @escaping () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { progressWaiters.append((condition, $0)) }
    }

    private func observationProgressed() {
        var remaining: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in progressWaiters {
            if waiter.condition() { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        progressWaiters = remaining
    }

    /// Removes a handle from the context. Its unsaved edits are dropped.
    public func forget<Record: SQLiteRecord>(_ model: SQLiteModel<Record>) throws(SQLiteError) {
        guard model.state != .saving, model.state != .indeterminate else {
            throw .misuse("\(Record.self) \(model.id) can't be forgotten while it is \(model.state)")
        }
        unregister(Record.self, id: model.id)
    }

    /// Whether the context manages a handle for this record.
    public func contains<Record: SQLiteRecord>(_ type: Record.Type, id: Record.ID) -> Bool {
        handles[Key(type: ObjectIdentifier(Record.self), id: AnyHashable(id))] != nil
    }

    private func register<Record: SQLiteRecord>(_ model: SQLiteModel<Record>, key: Key) {
        handles[key] = model
        order.append(key)
        decoders[Record.descriptor.table.name, default: [:]][ObjectIdentifier(Record.self)] = { change in
            change.id(as: Record.self).map(AnyHashable.init)
        }
    }

    func unregister<Record: SQLiteRecord>(_ type: Record.Type, id: Record.ID) {
        let key = Key(type: ObjectIdentifier(Record.self), id: AnyHashable(id))
        guard handles.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    // MARK: Saving

    /// Saves every dirty handle in one transaction, all or nothing.
    ///
    /// The edits are captured when the save starts. Edits made while it runs stay
    /// unsaved, and their handles stay dirty after it.
    ///
    /// - Returns: ``SQLiteSaveResult/saved(count:)``, or
    ///   ``SQLiteSaveResult/conflict(_:)`` if a row changed since its handle read it.
    /// - Throws: Errors of the write (busy, deadline, constraint, …); the handles are
    ///   dirty again with their edits. `SQLiteError.Code.commitOutcomeUnknown` if
    ///   the commit may or may not have happened; the handles become
    ///   ``SQLiteModel/State/indeterminate`` and further saves throw
    ///   `SQLiteError.Code.misuse` until ``resolveIndeterminate()``.
    ///   `SQLiteError.Code.interrupted` if the task was cancelled before the write.
    @discardableResult
    public func save() async throws(SQLiteError) -> SQLiteSaveResult {
        await beginExclusive()
        defer { endExclusive() }
        guard pending == nil else {
            throw .misuse("the outcome of an earlier save is unknown; call resolveIndeterminate() first")
        }
        guard !Task.isCancelled else { throw .interrupted }

        var captures: [CapturedWrite] = []
        do throws(SQLiteError) {
            for key in order {
                if let capture = try (handles[key] as? any ManagedModel)?.captureForSave() {
                    captures.append(capture)
                }
            }
        } catch {
            for capture in captures { capture.notCommitted() }
            throw error
        }
        guard !captures.isEmpty else { return .saved(count: 0) }

        if let hook = beforeWriteForTesting { await hook() }
        guard !Task.isCancelled else {
            for capture in captures { capture.notCommitted() }
            throw .interrupted
        }

        let marker = SQLiteRecordVersion.newIncarnation()
        let markersToDelete = committedMarkers
        let writes = captures.map(\.write)
        let createdAt = SQLiteModelSchema.nowMilliseconds()
        let inTransaction = inTransactionForTesting
        let table = SQLiteModelSchema.operationsTable
        let outcome: SQLiteRecordBatchOutcome
        do throws(SQLiteError) {
            outcome = try await store.managedWrite(origin: origin) { (tx) throws(SQLiteError) in
                for old in markersToDelete {
                    try tx.executeRaw("DELETE FROM \(table) WHERE id = ?", [.blob(old)])
                }
                try tx.executeRaw("INSERT INTO \(table) (id, created_at) VALUES (?, ?)", [.blob(marker), .integer(createdAt)])
                var reports: [SQLiteRecordWriteReport] = []
                for (index, write) in writes.enumerated() {
                    let report = try write.run(at: index, in: tx)
                    guard report.isApplied else { return .rollback((.rolledBack(failure: report), [])) }
                    reports.append(report)
                }
                try inTransaction?(tx)
                return .commit((.committed(reports), reports))
            }
            if reportNextCommitAsUnknownForTesting, case .committed = outcome {
                reportNextCommitAsUnknownForTesting = false
                throw .commitOutcomeUnknown(.misuse("simulated unknown outcome of a committed save"))
            }
        } catch {
            if error.code == .commitOutcomeUnknown {
                pending = PendingSave(marker: marker, deletedMarkers: markersToDelete, captures: captures)
                for capture in captures { capture.indeterminate() }
            } else {
                for capture in captures { capture.notCommitted() }
            }
            throw error
        }

        switch outcome {
        case .committed(let reports):
            markCommitted(marker: marker, deletedMarkers: markersToDelete)
            for (capture, report) in zip(captures, reports) { capture.committed(report) }
            return .saved(count: captures.count)
        case .rolledBack(let failure):
            for (index, capture) in captures.enumerated() {
                if index == failure.index { capture.conflicted(failure) } else { capture.notCommitted() }
            }
            return .conflict(SQLiteSaveConflict(
                table: failure.table, id: captures[failure.index].idDescription, found: failure.summary))
        }
    }

    /// Decides a save whose commit outcome is unknown, by looking for its marker on a
    /// fresh connection.
    ///
    /// If it committed, its handles move on as after an ordinary commit and are then
    /// refreshed, so a later remote change shows as usual. If not, they are dirty
    /// again with all their edits. If the check itself fails, the save stays
    /// indeterminate and the error is thrown.
    @discardableResult
    public func resolveIndeterminate() async throws(SQLiteError) -> SQLiteSaveResolution {
        await beginExclusive()
        defer { endExclusive() }
        guard let pending else { throw .misuse("no save has an unknown outcome") }
        let marker = pending.marker
        let table = SQLiteModelSchema.operationsTable
        let committed = try await database.resolveCommit { (tx) throws(SQLiteError) in
            !(try tx.queryRaw("SELECT 1 FROM \(table) WHERE id = ?", [.blob(marker)])).isEmpty
        }
        self.pending = nil
        guard committed else {
            for capture in pending.captures { capture.notCommitted() }
            return .notCommitted
        }
        markCommitted(marker: marker, deletedMarkers: pending.deletedMarkers)
        for capture in pending.captures { capture.committedWithoutReport() }
        for capture in pending.captures { try await capture.refresh(self) }
        return .committed
    }

    private func markCommitted(marker: [UInt8], deletedMarkers: [[UInt8]]) {
        committedMarkers.removeAll { deletedMarkers.contains($0) }
        committedMarkers.append(marker)
    }

    // Saves and resolutions run one at a time, in call order.
    private func beginExclusive() async {
        if saveInProgress {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            saveInProgress = true
        }
    }

    private func endExclusive() {
        if waiters.isEmpty {
            saveInProgress = false
        } else {
            waiters.removeFirst().resume()  // hand the turn over; stays in progress
        }
    }
}

@MainActor
protocol ManagedModel: AnyObject {
    func captureForSave() throws(SQLiteError) -> CapturedWrite?
    func makeRemoteRead() -> RemoteRead
    var knownVersion: SQLiteRecordVersion? { get }
}

extension SQLiteModel: ManagedModel {
    func captureForSave() throws(SQLiteError) -> CapturedWrite? { try capture() }
    func makeRemoteRead() -> RemoteRead { remoteRead() }
    var knownVersion: SQLiteRecordVersion? { (remote ?? baseline)?.version }
}
