// SPDX-License-Identifier: Apache-2.0

/// The `synchronous` setting for every connection.
public enum SQLiteSynchronous: String, Sendable, Hashable {
    /// `PRAGMA synchronous=FULL`, the default. In WAL mode, every commit syncs the WAL,
    /// so a committed transaction survives power loss.
    case full
    /// `PRAGMA synchronous=NORMAL`, an explicit opt-in. In WAL mode, the most recent
    /// commits can roll back after power loss or an OS crash (not after a process crash).
    case normal

    var pragmaValue: String {
        switch self {
        case .full: "FULL"
        case .normal: "NORMAL"
        }
    }
}

/// The iOS data-protection class for the database, WAL and shared-memory files.
///
/// It is passed to SQLite's `SQLITE_OPEN_FILEPROTECTION_*` open flags. It applies on
/// iOS only and is ignored on macOS and Linux.
public enum SQLiteFileProtection: String, Sendable, Hashable {
    /// Readable only while the device is unlocked.
    case complete
    /// Files that are already open stay usable after the device locks.
    case completeUnlessOpen
    /// Readable after the user unlocks the device once after boot.
    case completeUntilFirstUserAuthentication
    /// No data protection.
    case none

    /// The `SQLITE_OPEN_FILEPROTECTION_*` flag value (from Apple's `sqlite3.h`).
    var openFlag: Int32 {
        switch self {
        case .complete: 0x0010_0000
        case .completeUnlessOpen: 0x0020_0000
        case .completeUntilFirstUserAuthentication: 0x0030_0000
        case .none: 0x0040_0000
        }
    }
}

/// Size and count limits. All values come from configuration; nothing is unbounded.
public struct SQLiteLimits: Sendable, Hashable {
    /// The byte budget of one query result when the query doesn't set its own.
    /// Default: 1 MiB.
    public var defaultMaxResultBytes: Int
    /// The hard cap for any per-query byte budget, BLOB read, bound value and row.
    ///
    /// It is also applied as `SQLITE_LIMIT_LENGTH`, so SQLite itself refuses strings,
    /// BLOBs and rows larger than this with ``SQLiteError/tooBig(_:)``. Default: 16 MiB.
    public var hardMaxResultBytes: Int
    /// The row limit of one query when the query doesn't set its own. Default: 10,000.
    public var defaultMaxRows: Int
    /// The number of prepared statements each connection keeps cached (least recently
    /// used are finalized first). `0` disables the cache. Default: 32.
    public var statementCacheCapacity: Int

    public init(
        defaultMaxResultBytes: Int = 1 << 20,
        hardMaxResultBytes: Int = 16 << 20,
        defaultMaxRows: Int = 10_000,
        statementCacheCapacity: Int = 32
    ) {
        self.defaultMaxResultBytes = defaultMaxResultBytes
        self.hardMaxResultBytes = hardMaxResultBytes
        self.defaultMaxRows = defaultMaxRows
        self.statementCacheCapacity = statementCacheCapacity
    }

    func validate() throws(SQLiteError) {
        guard hardMaxResultBytes > 0, hardMaxResultBytes <= 1_000_000_000 else {
            throw .invalidConfiguration("hardMaxResultBytes must be in 1...1_000_000_000")
        }
        guard defaultMaxResultBytes > 0, defaultMaxResultBytes <= hardMaxResultBytes else {
            throw .invalidConfiguration("defaultMaxResultBytes must be in 1...hardMaxResultBytes")
        }
        guard defaultMaxRows > 0 else {
            throw .invalidConfiguration("defaultMaxRows must be positive")
        }
        guard (0...1024).contains(statementCacheCapacity) else {
            throw .invalidConfiguration("statementCacheCapacity must be in 0...1024")
        }
    }
}

/// Per-query limits. `nil` fields use the configured defaults from ``SQLiteLimits``.
public struct SQLiteQueryLimits: Sendable, Hashable {
    /// The maximum number of rows. More rows throw ``SQLiteError/rowLimitExceeded(limit:)``.
    public var maxRows: Int?
    /// The maximum total bytes of all values. More throw ``SQLiteError/resultTooLarge(limit:)``.
    /// Must not exceed ``SQLiteLimits/hardMaxResultBytes``.
    public var maxBytes: Int?

    public init(maxRows: Int? = nil, maxBytes: Int? = nil) {
        self.maxRows = maxRows
        self.maxBytes = maxBytes
    }
}

/// How to open a database.
///
/// The default is a file database in WAL mode with one writer connection and four
/// reader connections, `synchronous=FULL` and a 5-second busy timeout.
public struct SQLiteConfiguration: Sendable {
    /// Where the database lives.
    public enum Storage: Sendable, Hashable {
        /// A database file at this path. It is created if it doesn't exist.
        case file(path: String)
        /// A private in-memory database. Requires `readerCount == 0`.
        case inMemory
    }

    public var storage: Storage
    /// The number of read-only reader connections (default 4). `0` selects a single
    /// connection: reads then run on the writer connection, one at a time.
    public var readerCount: Int
    /// The `synchronous` setting. Default ``SQLiteSynchronous/full``.
    public var synchronous: SQLiteSynchronous
    /// How long a statement waits for a lock before failing with ``SQLiteError/busy(_:)``.
    /// Default 5 seconds; at most 10 minutes.
    public var busyTimeout: Duration
    /// Size and count limits.
    public var limits: SQLiteLimits
    /// `PRAGMA foreign_keys`. Default `true`.
    public var foreignKeys: Bool
    /// `PRAGMA wal_autocheckpoint` in pages. `0` turns automatic checkpoints off. Default 1000.
    public var walAutoCheckpointPages: Int
    /// `PRAGMA fullfsync` on Apple platforms: sync with `F_FULLFSYNC`, which also
    /// flushes the drive's write cache. Slower. Default `false` (SQLite's default).
    public var appleFullFSync: Bool
    /// The iOS data-protection class for new files. Ignored outside iOS. Default `nil`
    /// (the app's default class).
    public var fileProtection: SQLiteFileProtection?
    /// The clock used by expiry helpers. Default ``SQLiteSystemClock``.
    public var clock: any SQLiteClock

    /// A file database with the defaults described on ``SQLiteConfiguration``.
    public init(path: String) {
        self.storage = .file(path: path)
        self.readerCount = 4
        self.synchronous = .full
        self.busyTimeout = .seconds(5)
        self.limits = SQLiteLimits()
        self.foreignKeys = true
        self.walAutoCheckpointPages = 1000
        self.appleFullFSync = false
        self.fileProtection = nil
        self.clock = SQLiteSystemClock()
    }

    /// A file database that uses one connection for reads and writes.
    public static func singleConnection(path: String) -> SQLiteConfiguration {
        var configuration = SQLiteConfiguration(path: path)
        configuration.readerCount = 0
        return configuration
    }

    /// A private in-memory database (single connection).
    public static func inMemory() -> SQLiteConfiguration {
        var configuration = SQLiteConfiguration(path: ":memory:")
        configuration.storage = .inMemory
        configuration.readerCount = 0
        return configuration
    }

    func validate() throws(SQLiteError) {
        try limits.validate()
        guard (0...64).contains(readerCount) else {
            throw .invalidConfiguration("readerCount must be in 0...64")
        }
        guard busyTimeout >= .zero, busyTimeout <= .seconds(600) else {
            throw .invalidConfiguration("busyTimeout must be in 0...600 seconds")
        }
        guard walAutoCheckpointPages >= 0 else {
            throw .invalidConfiguration("walAutoCheckpointPages must not be negative")
        }
        switch storage {
        case .inMemory:
            guard readerCount == 0 else {
                throw .invalidConfiguration("an in-memory database requires readerCount == 0")
            }
        case .file(let path):
            guard !path.isEmpty, !path.utf8.contains(0) else {
                throw .invalidConfiguration("the database path must be non-empty and contain no NUL")
            }
            guard path != ":memory:", !path.hasPrefix("file:") else {
                throw .invalidConfiguration("use .inMemory instead of special filenames or URIs")
            }
        }
    }
}
