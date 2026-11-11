// SPDX-License-Identifier: Apache-2.0

#if os(Linux)
internal import CSQLiteSwift
#else
internal import SQLite3
#endif

/// A bounded least-recently-used cache of prepared statements for one connection.
///
/// Used only on the connection's worker thread. Evicted statements are finalized.
final class SQLiteStatementCache {
    let capacity: Int
    private var statements: [String: OpaquePointer] = [:]
    /// Least recently used first.
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { statements.count }

    func lookup(_ sql: String) -> OpaquePointer? {
        guard let statement = statements[sql] else { return nil }
        if let index = order.firstIndex(of: sql), index != order.count - 1 {
            order.remove(at: index)
            order.append(sql)
        }
        return statement
    }

    /// Stores a statement. Returns `false` (and leaves ownership with the caller) if
    /// caching is disabled.
    func insert(_ sql: String, _ statement: OpaquePointer) -> Bool {
        guard capacity > 0 else { return false }
        if let existing = statements[sql] {
            sqlite3_finalize(existing)
            order.removeAll { $0 == sql }
        }
        while statements.count >= capacity, let oldest = order.first {
            order.removeFirst()
            if let evicted = statements.removeValue(forKey: oldest) {
                sqlite3_finalize(evicted)
            }
        }
        statements[sql] = statement
        order.append(sql)
        return true
    }

    func finalizeAll() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        order.removeAll()
    }
}
