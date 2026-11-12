// SPDX-License-Identifier: Apache-2.0

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
    }

    /// A migration that runs a SQL script (several `;`-separated statements).
    public init(version: Int, name: String, sql: String) {
        self.init(version: version, name: name) { (transaction) throws(SQLiteError) in
            try transaction.executeScript(sql)
        }
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
            try checkCancelled()
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
                try checkCancelled()
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
