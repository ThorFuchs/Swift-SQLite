// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif

/// One forward-only schema migration.
///
/// Migrations are numbered `1, 2, 3, …` without gaps. On open, each migration
/// newer than the database's `PRAGMA user_version` runs in its own `BEGIN IMMEDIATE`
/// transaction, which also sets `user_version` to the migration's version. A failing
/// migration rolls back alone; earlier ones stay committed.
public struct SQLiteMigration: Sendable {
    public let version: Int
    public let name: String
    let body: @Sendable (SQLiteTransaction) throws(SQLiteError) -> Void
    /// The SQL text of a SQL migration; `nil` for a closure.
    let sql: String?

    /// A fingerprint of the migration (64-bit FNV-1a, hex): of the version, the name
    /// and, for a SQL migration, the SQL text. A closure can't be fingerprinted, so a
    /// closure migration's checksum covers only its version and name.
    ///
    /// Used by ``SQLiteConfiguration/verifiesMigrationChecksums`` to detect a shipped
    /// migration that was edited. It detects accidents, not tampering.
    public var checksum: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(version)\u{0}\(name)\u{0}\(sql ?? "")".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Runs the migration's body in `transaction` (without touching `user_version`).
    ///
    /// SQLiteSwift calls this during ``SQLiteDatabase/open(_:migrations:)``. It is
    /// public so test kits can wrap migrations.
    public func apply(in transaction: SQLiteTransaction) throws(SQLiteError) {
        try body(transaction)
    }

    /// A migration that runs Swift code in its transaction.
    public init(
        version: Int, name: String,
        _ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> Void
    ) {
        self.version = version
        self.name = name
        self.body = body
        self.sql = nil
    }

    /// A migration that runs a SQL script (several `;`-separated statements).
    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
        self.body = { (transaction) throws(SQLiteError) in try transaction.executeScript(sql) }
    }

    static func validate(_ migrations: [SQLiteMigration]) throws(SQLiteError) {
        for (offset, migration) in migrations.enumerated() where migration.version != offset + 1 {
            throw .invalidConfiguration(
                "migration versions must be 1, 2, 3, … without gaps; position \(offset) has version \(migration.version)")
        }
    }
}

extension SQLiteConnectionCore {
    /// Refuses databases newer than the known migrations, without writing anything.
    func checkSchemaVersion(supported: Int) throws(SQLiteError) -> Int {
        guard case .integer(let raw) = try scalarInternal("PRAGMA user_version") else { return 0 }
        let version = Int(raw)
        if version > supported {
            throw .schemaTooNew(databaseVersion: version, supportedVersion: supported)
        }
        return version
    }

    /// Applies pending migrations, one transaction each.
    func migrate(_ migrations: [SQLiteMigration]) throws(SQLiteError) {
        let supported = migrations.count
        let start = try checkSchemaVersion(supported: supported)
        for migration in migrations where migration.version > start {
            try checkStop()
            try execInternal("BEGIN IMMEDIATE")
            do throws(SQLiteError) {
                // Re-read inside the write lock: another process may have migrated.
                let current = try checkSchemaVersion(supported: supported)
                if current >= migration.version {
                    try execInternal("COMMIT")
                    continue
                }
                let transaction = SQLiteTransaction(core: self, kind: .write)
                defer { transaction.invalidate() }
                do throws(SQLiteError) {
                    try migration.body(transaction)
                } catch {
                    throw SQLiteError.migrationFailed(
                        version: migration.version, name: migration.name, underlying: error)
                }
                try checkStop()
                try execInternal("PRAGMA user_version = \(migration.version)")
                do throws(SQLiteError) {
                    try commitTransaction()
                } catch {
                    throw SQLiteError.migrationFailed(
                        version: migration.version, name: migration.name, underlying: error)
                }
            } catch {
                rollbackIfNeeded()
                throw error
            }
        }
    }
}

// MARK: Checksums

extension SQLiteConnectionCore {
    static let checksumTable = "sqliteswift_migration_checksums"

    /// Checks the applied migrations against their stored checksums and records the
    /// ones that have none. Throws ``SQLiteError/Code/migrationModified`` on a change.
    func reconcileMigrationChecksums(_ migrations: [SQLiteMigration]) throws(SQLiteError) {
        try execInternal("BEGIN IMMEDIATE")
        do throws(SQLiteError) {
            try execInternal("""
                CREATE TABLE IF NOT EXISTS \(Self.checksumTable) (
                    version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL)
                """)
            guard case .integer(let raw) = try scalarInternal("PRAGMA user_version") else {
                try execInternal("COMMIT")
                return
            }
            for migration in migrations.prefix(Int(raw)) {
                let (statement, _) = try prepare(
                    "SELECT checksum FROM \(Self.checksumTable) WHERE version = ?", cached: false)
                defer { release(statement, isCached: false) }
                try bind([SQLiteValue.integer(Int64(migration.version))], to: statement)
                let rc = sqlite3_step(statement)
                if rc == SQLITE_ROW {
                    let stored = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                    guard stored == migration.checksum else {
                        throw .migrationModified(version: migration.version, name: migration.name,
                                                 expected: stored, actual: migration.checksum)
                    }
                } else if rc == SQLITE_DONE {
                    let (insert, _) = try prepare(
                        "INSERT INTO \(Self.checksumTable) (version, name, checksum) VALUES (?, ?, ?)", cached: false)
                    defer { release(insert, isCached: false) }
                    try bind([SQLiteValue.integer(Int64(migration.version)), .text(migration.name),
                              .text(migration.checksum)], to: insert)
                    let done = sqlite3_step(insert)
                    guard done == SQLITE_DONE else { throw error(done) }
                } else {
                    throw error(rc)
                }
            }
            try execInternal("COMMIT")
        } catch {
            rollbackIfNeeded()
            throw error
        }
    }
}
