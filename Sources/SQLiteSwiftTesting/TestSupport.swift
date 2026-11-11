// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import SQLiteSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A clock that only moves when told to. Inject it as ``SQLiteConfiguration/clock``.
public final class SQLiteManualClock: SQLiteClock {
    private let current: Mutex<SQLiteTimestamp>

    public init(_ start: SQLiteTimestamp = SQLiteTimestamp(millisecondsSince1970: 1_700_000_000_000)) {
        current = Mutex(start)
    }

    public func now() -> SQLiteTimestamp {
        current.withLock { $0 }
    }

    /// Moves the clock forward (or backward, for a negative duration).
    public func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }

    /// Sets the clock.
    public func set(_ timestamp: SQLiteTimestamp) {
        current.withLock { $0 = timestamp }
    }
}

/// A fresh temporary directory, removed by ``remove()`` or on deinit.
public final class SQLiteTemporaryDirectory: Sendable {
    public let path: String

    public init(prefix: String = "sqliteswift") throws {
        let base = FileManager.default.temporaryDirectory.path
        var template = Array("\(base)/\(prefix).XXXXXX".utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        path = String(cString: created)
    }

    deinit { remove() }

    /// A path for a file inside the directory.
    public func file(_ name: String) -> String {
        "\(path)/\(name)"
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A one-shot flag that worker-thread code can wait on (bounded) and async code can set.
///
/// Transaction closures run synchronously on a connection's thread. Tests use a
/// latch to hold a transaction open while they do something else.
public final class SQLiteTestLatch: Sendable {
    private let opened = Atomic<Bool>(false)
    private let entered = Atomic<Bool>(false)

    public init() {}

    /// Opens the latch; waiting code continues.
    public func open() { opened.store(true, ordering: .sequentiallyConsistent) }
    public var isOpen: Bool { opened.load(ordering: .sequentiallyConsistent) }

    /// Called by the waiting side to signal that it reached the latch.
    public func markEntered() { entered.store(true, ordering: .sequentiallyConsistent) }
    public var hasEntered: Bool { entered.load(ordering: .sequentiallyConsistent) }

    /// Blocks the calling (worker) thread until the latch opens or `timeout` passes.
    /// Returns `true` if the latch opened.
    @discardableResult
    public func blockingWait(timeout: Duration = .seconds(10)) -> Bool {
        markEntered()
        let deadline = ContinuousClock.now + timeout
        while !isOpen {
            if ContinuousClock.now >= deadline { return false }
            usleep(1000)
        }
        return true
    }

    /// Suspends until the waiting side has reached the latch, or `timeout` passes.
    /// Returns `true` if it did.
    @discardableResult
    public func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !hasEntered {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}

/// Copies a database's files as they are on disk right now, the way a crash or
/// power loss would leave them.
public enum SQLiteCrashImage {
    /// Copies `<source>`, `<source>-wal` and (unless `dropSharedMemory`) `<source>-shm`
    /// to `destination` and the matching suffixes.
    ///
    /// Dropping the `-shm` file forces SQLite to rebuild the WAL index from the WAL,
    /// as it does after a reboot.
    /// - Returns: The size of the copied WAL in bytes (0 if there was none).
    @discardableResult
    public static func capture(
        databasePath source: String, to destination: String, dropSharedMemory: Bool = true
    ) throws -> Int {
        let manager = FileManager.default
        var walBytes = 0
        let suffixes = dropSharedMemory ? ["", "-wal"] : ["", "-wal", "-shm"]
        for suffix in suffixes {
            let from = source + suffix
            let to = destination + suffix
            guard manager.fileExists(atPath: from) else { continue }
            if manager.fileExists(atPath: to) { try manager.removeItem(atPath: to) }
            let data = try Data(contentsOf: URL(fileURLWithPath: from))
            try data.write(to: URL(fileURLWithPath: to))
            if suffix == "-wal" { walBytes = data.count }
        }
        return walBytes
    }

    /// The size of a file in bytes, or `nil` if it doesn't exist.
    public static func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }

    /// The bytes of a file, or `nil` if it doesn't exist.
    public static func contents(_ path: String) -> [UInt8]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { [UInt8]($0) }
    }
}
