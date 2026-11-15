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
