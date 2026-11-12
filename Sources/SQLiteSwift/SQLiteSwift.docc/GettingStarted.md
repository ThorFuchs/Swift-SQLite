# Getting Started

Open a database, define its schema with migrations, then read and write in
transactions.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", branch: "main"),
],
targets: [
    .target(name: "MyStore", dependencies: [
        .product(name: "SQLiteSwift", package: "Swift-SQLite"),
    ]),
    .testTarget(name: "MyStoreTests", dependencies: [
        "MyStore",
        .product(name: "SQLiteSwiftTesting", package: "Swift-SQLite"),
    ]),
]
```

## Define migrations

Migrations are numbered `1, 2, 3, …` without gaps. Each one runs once, in its own
transaction, which also sets `PRAGMA user_version`.

```swift
import SQLiteSwift

let migrations = [
    SQLiteMigration(version: 1, name: "tasks", sql: """
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            version INTEGER NOT NULL DEFAULT 1,
            state TEXT NOT NULL,
            payload BLOB NOT NULL,
            expires_at INTEGER
        );
        """),
    SQLiteMigration(version: 2, name: "expiry index") { tx throws(SQLiteError) in
        try tx.execute("CREATE INDEX tasks_by_expiry ON tasks(expires_at)")
    },
]
```

Never edit or remove a migration after it shipped; add a new one.

## Open the database

```swift
var configuration = SQLiteConfiguration(path: databasePath)
// Defaults: WAL, 1 writer + 4 readers, synchronous=FULL, 5 s busy timeout,
// 1 MiB result budget, 16 MiB hard cap, 10,000 rows per query.
let database = try await SQLiteDatabase.open(configuration, migrations: migrations)
defer { Task { await database.close() } }
```

If the file was written by newer code (its `user_version` is higher than your
migration count), `open` throws ``SQLiteError/schemaTooNew(databaseVersion:supportedVersion:)``
and writes nothing.

## Write

`write` runs its closure in a `BEGIN IMMEDIATE` transaction on the writer
connection's thread and returns after `COMMIT`. If the closure throws, the
transaction rolls back.

```swift
try await database.write { tx throws(SQLiteError) in
    try tx.execute(
        "INSERT INTO tasks (id, state, payload, expires_at) VALUES (?, ?, ?, ?)",
        [.text(id), "working", .blob(canonicalJSONBytes), tx.deadline(after: .seconds(3600)).sqliteValue])
}
```

Values pass as ``SQLiteValue``. Store JSON as canonical bytes in a BLOB;
SQLiteSwift doesn't interpret them.

## Compare-and-set

Use a version column for optimistic concurrency. A conflict is a result value, so
your store decides what it means.

```swift
let result = try await database.write { tx throws(SQLiteError) in
    try tx.compareAndSet(
        table: "tasks", id: .text(id), expectedVersion: readVersion,
        assignments: [SQLiteAssignment("state", "completed")])
}
switch result {
case .updated(let newVersion): ...
case .conflict(let currentVersion): ...
case .notFound: ...
}
```

To discard other changes on a conflict, use ``SQLiteDatabase/writeOrRollback(_:)``
and return `.rollback(value)`.

Add a typed guard to make the update conditional on more than the version, in the
same atomic statement. Values are bound, never pasted into SQL:

```swift
let result = try await database.write { tx throws(SQLiteError) in
    try tx.compareAndSet(
        table: "tasks", id: .text(id), expectedVersion: readVersion,
        assignments: [SQLiteAssignment("state", "cancelled")],
        alsoRequire: .notIn("state", ["completed", "failed", "cancelled"]))
}
// .guardFailed(currentVersion:) means: right version, but already terminal.
```

## Read

`read` runs on a reader connection in a deferred transaction, so every statement in
the closure sees the same snapshot.

```swift
let rows = try await database.read { tx throws(SQLiteError) in
    try tx.query("SELECT id, state FROM tasks WHERE state = ?", ["working"],
                 limits: SQLiteQueryLimits(maxRows: 100))
}
```

Results are never silently truncated. Too many rows throw
``SQLiteError/rowLimitExceeded(limit:)``; too many bytes throw
``SQLiteError/resultTooLarge(limit:)``. For a single large value, use
``SQLiteTransaction/readBlob(table:column:keyColumn:key:maxBytes:)``. It checks
`length(column)` before loading anything.

## Page through rows

For bounded batch scans (recovery after a restart, expiry sweeps), use keyset
pagination over `NOT NULL` key columns that identify a row uniquely:

```swift
var cursor: SQLiteKeysetCursor?
repeat {
    let page = try await database.read { [cursor] tx throws(SQLiteError) in
        try tx.queryPage(
            table: "tasks", columns: ["id", "state"], keyColumns: ["created_at", "id"],
            after: cursor, filter: .notIn("state", ["completed", "failed", "cancelled"]),
            limit: 100)
    }
    // handle page.rows
    cursor = page.nextCursor
} while cursor != nil
```

## Expiry and time

Expiry helpers read time only from ``SQLiteConfiguration/clock``. Inject
`SQLiteManualClock` from SQLiteSwiftTesting in tests.

```swift
try await database.write { tx throws(SQLiteError) in
    try tx.deleteExpired(from: "tasks", expiresAtColumn: "expires_at", limit: 500)
}
```

## Commit outcomes

`write` returns after `COMMIT` succeeded. When it throws, the transaction was not
committed, with one exception: ``SQLiteError/commitOutcomeUnknown(_:)`` means
`COMMIT` was issued, failed, and the transaction is no longer open, so the write may
or may not be durable. Generate keys before the write, and on this error resolve with
a fresh read of that key before replying to anyone:

```swift
do {
    try await database.write { tx throws(SQLiteError) in
        try tx.execute("INSERT INTO tasks (id, state, payload) VALUES (?, ?, ?)",
                       [.text(id), "working", .blob(bytes)])
    }
} catch SQLiteError.commitOutcomeUnknown(_) {
    let exists = try await database.read { tx throws(SQLiteError) in
        try tx.queryOne("SELECT 1 FROM tasks WHERE id = ?", [.text(id)]) != nil
    }
    // reply only if `exists`
}
```

## Cancellation, busy and errors

- Cancelling the calling task interrupts the running statement, rolls back and
  throws ``SQLiteError/interrupted``.
- If another process holds the write lock longer than
  ``SQLiteConfiguration/busyTimeout``, the call throws ``SQLiteError/busy(_:)``.
- A full disk (or `max_page_count`) throws ``SQLiteError/full(_:)``; the
  transaction is rolled back and the database stays usable.
- A database file that isn't writable fails at open with ``SQLiteError/readOnly(_:)``;
  a missing or inaccessible directory with ``SQLiteError/cantOpen(_:)``. I/O errors
  arrive as ``SQLiteError/ioError(_:)`` with SQLite's extended code.
- On Apple platforms, writes are synced with `F_FULLFSYNC` by default
  (``SQLiteConfiguration/appleFullFSync``). ``SQLiteDatabase/effectiveSettings()``
  reports the settings in force.

## Test your store with the conformance kit

```swift
import SQLiteSwiftTesting
import Testing

@Test(arguments: SQLiteConformanceKit.Check.allCases)
func conformance(check: SQLiteConformanceKit.Check) async {
    let kit = SQLiteConformanceKit(migrations: migrations)
    let result = await kit.run(check)
    #expect(result.outcome == .passed, "\(result.notes)")
}
```

The kit checks migrations, refusal of newer schemas, compare-and-set conflicts,
busy contention, cancellation, WAL checkpoints, recovery from a crash image taken
in the middle of a write, and `SQLITE_FULL`, all with your migrations and
configuration.
