// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLiteSwift

/// The tables the editing context owns.
///
/// Add ``migration(version:)`` to your own numbered migration list, so your
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

    /// The migration that creates the context's tables.
    public static func migration(version: Int, name: String = "sqliteswift model context") -> SQLiteMigration {
        SQLiteMigration(version: version, name: name, sql: """
            CREATE TABLE \(operationsTable) (
                id BLOB PRIMARY KEY CHECK (length(id) = 16),
                created_at INTEGER NOT NULL
            ) WITHOUT ROWID;
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

    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
