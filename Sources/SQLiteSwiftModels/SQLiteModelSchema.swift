// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift

/// The tables the model store and the editing context own.
///
/// Add ``migration(version:name:)`` to your own numbered migration list, so your
/// `user_version` stays the single schema version of the file:
///
/// ```swift
/// let migrations = [
///     SQLiteMigration(version: 1, name: "articles", sql: "CREATE TABLE articles (…)"),
///     SQLiteModelSchema.migration(version: 2),
/// ]
/// ```
public enum SQLiteModelSchema {
    /// The table of save markers: one short-lived row per save, used to decide a
    /// commit whose outcome is unknown.
    public static let operationsTable = "sqliteswift_model_operations"

    /// The one-row table whose value counts the store's committed batches.
    public static let sequenceTable = "sqliteswift_model_sequence"

    /// The change log's batches (sequence and origin), for resumable subscriptions.
    public static let changeBatchesTable = "sqliteswift_model_change_batches"
    /// The change log's record changes, in batch order.
    public static let changesTable = "sqliteswift_model_changes"

    /// The migration that creates the change log a store with a
    /// ``SQLiteModelStore/ChangeLog`` writes to. Add it after
    /// ``migration(version:name:)``, as its own numbered migration.
    public static func changeLogMigration(version: Int, name: String = "sqliteswift model change log") -> SQLiteMigration {
        // record_key has no declared type, so keys keep their exact storage class.
        SQLiteMigration(version: version, name: name, sql: """
            CREATE TABLE \(changeBatchesTable) (
                sequence INTEGER PRIMARY KEY,
                origin BLOB
            );
            CREATE TABLE \(changesTable) (
                sequence INTEGER NOT NULL,
                position INTEGER NOT NULL,
                table_name TEXT NOT NULL,
                record_key,
                kind INTEGER NOT NULL CHECK (kind IN (0, 1, 2)),
                revision INTEGER,
                incarnation BLOB,
                PRIMARY KEY (sequence, position)
            ) WITHOUT ROWID;
            """)
    }

    /// The migration that creates the store's tables.
    public static func migration(version: Int, name: String = "sqliteswift model store") -> SQLiteMigration {
        SQLiteMigration(version: version, name: name, sql: """
            CREATE TABLE \(operationsTable) (
                id BLOB PRIMARY KEY CHECK (length(id) = 16),
                created_at INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE \(sequenceTable) (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                value INTEGER NOT NULL CHECK (value >= 0)
            );
            INSERT INTO \(sequenceTable) (id, value) VALUES (1, 0);
            """)
    }

    /// Deletes save markers older than `age`.
    ///
    /// A marker is normally deleted by the next save of the context that wrote it. One
    /// is left behind only if the process ended first. Run this once after opening the
    /// database; markers of saves that are still unresolved in a live context must be
    /// younger than `age`.
    ///
    /// - Returns: The number of markers deleted.
    @discardableResult
    public static func pruneMarkers(
        in database: SQLiteDatabase, olderThan age: Duration = .seconds(7 * 24 * 3600)
    ) async throws(SQLiteError) -> Int {
        let cutoff = nowMilliseconds() - age.components.seconds * 1000
        return try await database.write { (tx) throws(SQLiteError) in
            try tx.execute("DELETE FROM \(operationsTable) WHERE created_at < ?", [.integer(cutoff)]).changedRows
        }
    }

    package static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
