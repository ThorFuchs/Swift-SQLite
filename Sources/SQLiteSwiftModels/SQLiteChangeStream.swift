// SPDX-License-Identifier: Apache-2.0

import SQLiteSwift

/// Who made a change: an opaque token a writer passes along, so it can recognize
/// its own changes in the stream.
public struct SQLiteChangeOrigin: Sendable, Hashable, CustomStringConvertible {
    let value: [UInt8]

    /// A new, unique origin.
    public init() {
        value = SQLiteRecordVersion.newIncarnation()
    }

    public var description: String {
        "origin " + value.prefix(4).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}

/// One record changed by a committed batch. It carries the record's identity, not
/// its stored values: read the row if you need them.
public struct SQLiteRecordChange: Sendable, Hashable {
    /// What happened to the record.
    ///
    /// The cases are complete; no case will be added.
    public enum Kind: Sendable, Hashable {
        case inserted, updated, deleted
    }

    /// The record's table.
    public let table: String
    /// The stored form of the record's key.
    public let key: SQLiteRawValue
    public let kind: Kind
    /// The version after the change; `nil` for a deletion.
    public let version: SQLiteRecordVersion?

    /// The record's key as `Record.ID`, or `nil` if the change is for another table
    /// or the key doesn't decode.
    public func id<Record: SQLiteRecord>(as type: Record.Type) -> Record.ID? {
        let descriptor = Record.descriptor
        guard table == descriptor.table.name else { return nil }
        return try? descriptor.keyCodec.decode(key, column: descriptor.keyColumn)
    }

    init?(_ report: SQLiteRecordWriteReport) {
        table = report.table
        key = report.key
        switch report.summary {
        case .inserted(let v): kind = .inserted; version = v
        case .updated(let v): kind = .updated; version = v
        case .deleted: kind = .deleted; version = nil
        case .conflict, .missing: return nil
        }
    }
}

/// A batch the store committed.
public struct SQLiteCommittedChange: Sendable, Hashable {
    /// The batch's place in commit order: 1, 2, 3, … per database file.
    public let sequence: Int64
    /// The writer's origin, if it passed one.
    public let origin: SQLiteChangeOrigin?
    /// The changed records, in the batch's order.
    public let changes: [SQLiteRecordChange]
}

/// What a change subscription delivers.
///
/// The cases are complete; no case will be added.
public enum SQLiteChangeEvent: Sendable, Hashable {
    /// A committed batch, newer than the subscription's snapshot.
    case committed(SQLiteCommittedChange)
    /// The subscriber may have missed changes: its buffer overflowed, or a write's
    /// commit outcome is unknown. Read a new snapshot with a new subscription. The
    /// subscription ends after this event.
    case resyncRequired
}

/// The committed changes after a snapshot, in commit order.
///
/// Iterate it in one task. It ends when that task is cancelled, after
/// ``SQLiteChangeEvent/resyncRequired``, or when the store closes. It holds at most
/// its buffer size of undelivered events.
public final class SQLiteChangeSubscription: AsyncSequence, Sendable {
    public typealias Element = SQLiteChangeEvent
    public typealias Failure = Never

    let id: UInt64
    let hub: SQLiteChangeHub

    init(id: UInt64, hub: SQLiteChangeHub) {
        self.id = id
        self.hub = hub
    }

    deinit {
        hub.remove(id)
    }

    /// Ends the subscription now.
    public func cancel() {
        hub.remove(id)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(subscription: self)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscription: SQLiteChangeSubscription

        public mutating func next() async -> SQLiteChangeEvent? {
            await subscription.hub.next(subscription.id)
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> SQLiteChangeEvent? {
            await subscription.hub.next(subscription.id)
        }
    }
}

/// Fans committed batches out to bounded subscriber buffers.
final class SQLiteChangeHub: Sendable {
    private struct Subscriber: Sendable {
        var queue: [SQLiteChangeEvent] = []
        let capacity: Int
        /// Sequences at or below it are in the subscriber's snapshot; `nil` while
        /// the snapshot is being read.
        var watermark: Int64?
        /// Ends after the queue drains.
        var ending = false
        var waiter: CheckedContinuation<SQLiteChangeEvent?, Never>?
    }

    private struct State: Sendable {
        var nextID: UInt64 = 1
        var subscribers: [UInt64: Subscriber] = [:]
        var closed = false
    }

    private let state = SQLiteLocked(State())

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    func add(capacity: Int) throws(SQLiteError) -> UInt64 {
        try state.withLock { (state) throws(SQLiteError) -> UInt64 in
            guard !state.closed else { throw .closed }
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = Subscriber(capacity: capacity)
            return id
        }
    }

    /// Sets the snapshot's sequence and drops what it already contains.
    func setWatermark(_ watermark: Int64, for id: UInt64) {
        state.withLock { state in
            guard var subscriber = state.subscribers[id] else { return }
            subscriber.watermark = watermark
            subscriber.queue.removeAll { event in
                if case .committed(let change) = event { return change.sequence <= watermark }
                return false
            }
            state.subscribers[id] = subscriber
        }
    }

    func publish(_ change: SQLiteCommittedChange) {
        deliver { subscriber in
            if let watermark = subscriber.watermark, change.sequence <= watermark { return }
            if subscriber.queue.count >= subscriber.capacity {
                subscriber.queue = [.resyncRequired]
                subscriber.ending = true
            } else {
                subscriber.queue.append(.committed(change))
            }
        }
    }

    /// Tells every subscriber it may have missed a change.
    func resyncAll() {
        deliver { subscriber in
            subscriber.queue = [.resyncRequired]
            subscriber.ending = true
        }
    }

    /// Ends every subscription and refuses new ones.
    func close() {
        let waiters = state.withLock { state -> [CheckedContinuation<SQLiteChangeEvent?, Never>] in
            state.closed = true
            let waiters = state.subscribers.values.compactMap(\.waiter)
            state.subscribers = [:]
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func remove(_ id: UInt64) {
        let waiter = state.withLock { $0.subscribers.removeValue(forKey: id)?.waiter }
        waiter?.resume(returning: nil)
    }

    func next(_ id: UInt64) async -> SQLiteChangeEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SQLiteChangeEvent?, Never>) in
                let ready: SQLiteChangeEvent?? = state.withLock { state in
                    guard var subscriber = state.subscribers[id], subscriber.waiter == nil else {
                        return .some(nil)
                    }
                    if Task.isCancelled {
                        state.subscribers[id] = nil
                        return .some(nil)
                    }
                    if !subscriber.queue.isEmpty {
                        let event = subscriber.queue.removeFirst()
                        if subscriber.ending && subscriber.queue.isEmpty {
                            state.subscribers[id] = nil
                        } else {
                            state.subscribers[id] = subscriber
                        }
                        return .some(event)
                    }
                    subscriber.waiter = continuation
                    state.subscribers[id] = subscriber
                    return .none
                }
                if case .some(let event) = ready { continuation.resume(returning: event) }
            }
        } onCancel: {
            remove(id)
        }
    }

    /// Applies `change` to every subscriber and wakes those with a waiting consumer.
    private func deliver(_ change: (inout Subscriber) -> Void) {
        let woken = state.withLock { state -> [(CheckedContinuation<SQLiteChangeEvent?, Never>, SQLiteChangeEvent)] in
            var woken: [(CheckedContinuation<SQLiteChangeEvent?, Never>, SQLiteChangeEvent)] = []
            for id in state.subscribers.keys {
                guard var subscriber = state.subscribers[id] else { continue }
                change(&subscriber)
                if let waiter = subscriber.waiter, !subscriber.queue.isEmpty {
                    subscriber.waiter = nil
                    let event = subscriber.queue.removeFirst()
                    woken.append((waiter, event))
                    if subscriber.ending && subscriber.queue.isEmpty {
                        state.subscribers[id] = nil
                        continue
                    }
                }
                state.subscribers[id] = subscriber
            }
            return woken
        }
        for (waiter, event) in woken { waiter.resume(returning: event) }
    }
}
