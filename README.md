# Swift-SQLite

Durable, bounded SQLite persistence for Swift concurrency. It is the shared SQLite
base for the Swift-JSON package family (MCP task stores, content-collection stores,
versioned JSON envelopes). Domain logic stays in the consuming packages.

- **Products:** `SQLiteSwift` (library) and `SQLiteSwiftTesting` (conformance kit and
  test helpers).
- **Platforms:** macOS 15, iOS 18, Linux. Swift 6.4 tools, Swift 6 language mode,
  strict concurrency.
- **Dependencies:** none. Apple platforms link the system SQLite. Linux compiles a
  pinned, unmodified SQLite 3.54.1 amalgamation
  ([provenance](Sources/CSQLiteSwift/PROVENANCE.md)).
- **License:** Apache-2.0. SQLite itself is public domain; see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## What it guarantees

| Area | Behavior |
| --- | --- |
| Connections | One writer (`BEGIN IMMEDIATE`) plus a bounded reader pool (default 4) on WAL snapshot transactions. `readerCount = 0` selects a single connection. |
| Threads | Each connection runs SQLite calls on its own thread, never on the cooperative pool. `close()` lets running work finish, fails waiting work with `.closed` and joins the threads before it returns. No detached tasks, no global singletons. |
| Durability | Writes return only after `COMMIT`. `synchronous=FULL` by default (`NORMAL` only as an explicit opt-in); on Apple platforms also `fullfsync` and `checkpoint_fullfsync` (`F_FULLFSYNC`) by default. Every applied setting is read back at open; a mismatch throws `.settingMismatch`. `effectiveSettings()` reports what is in force. |
| Busy | Bounded busy timeout (default 5 s) → `SQLiteError` code `.busy`. |
| Cancellation | Task cancellation → `sqlite3_interrupt` → rollback → code `.interrupted`. |
| Operation limits | Per-call or default deadlines and VM-instruction budgets (`SQLiteOperationLimits`), covering the wait for a connection and for locks → rollback → `.deadlineExceeded` / `.instructionLimitExceeded`. The first cause is reported; a stop never reaches the next operation. |
| Migrations | `PRAGMA user_version`, forward-only, one transaction per migration. A newer database is refused with `.schemaTooNew` and left untouched. |
| Commit outcomes | A thrown error means "not committed", except `.commitOutcomeUnknown`: `COMMIT` was issued, failed, and the transaction ended. `resolveCommit` decides it with a fresh read on a new connection; `writeReportingOutcome` returns `.committed` / `.notCommitted` / `.unknown` as a value. |
| File identity | Optional `SQLiteFileIdentity` (`application_id`, `page_size`, `auto_vacuum`): written to new files, checked on existing ones; the wrong file is refused with `.fileIdentityMismatch` and left untouched. |
| Compare-and-set | `UPDATE … SET version = version + 1 WHERE id = ? AND version = ? [AND guard]` in one statement. Results: `.updated`, `.conflict(currentVersion:)`, `.guardFailed(currentVersion:)` (typed `SQLitePredicate` guard with bound values), `.notFound`. |
| Pagination | Keyset pages (`queryPage`) over `(k1, k2, …)` with an optional typed filter, for bounded batch scans. |
| Bounded reads | Per-query row limits, byte budgets (1 MiB default, 16 MiB hard cap, also applied as `SQLITE_LIMIT_LENGTH`), `length(col)` checks before loading BLOBs, and a bounded LRU statement cache. Results are never silently truncated. |
| Byte-exact values | `queryRaw` / `executeRaw` with `SQLiteRawValue` keep TEXT as its stored bytes, including invalid UTF-8 and NUL. |
| Time | Expiry helpers read only the injected `SQLiteClock`. |
| Errors | `SQLiteError` is a struct with a `code` that can grow without breaking your `switch`: busy, constraint, corrupt, full, read-only, can't open, I/O error (with extended code), too big, interrupted, deadline, instruction limit, commit outcome unknown, setting and file-identity mismatch, schema too new, migration failed, limits, closed, misuse, and `.sqlite` for every other result code. Catch by code: `catch SQLiteError.Code.busy`. A non-writable database file fails at open with `.readOnly`. |
| iOS | Optional data-protection class via `SQLITE_OPEN_FILEPROTECTION_*`. |

## Quick start

```swift
import SQLiteSwift

let database = try await SQLiteDatabase.open(
    SQLiteConfiguration(path: path),
    migrations: [
        SQLiteMigration(version: 1, name: "items", sql: """
            CREATE TABLE items (id TEXT PRIMARY KEY, version INTEGER NOT NULL DEFAULT 1, body BLOB NOT NULL);
            """)
    ])

try await database.write { tx throws(SQLiteError) in
    try tx.execute("INSERT INTO items (id, body) VALUES (?, ?)", ["a", .blob(canonicalJSON)])
}

let result = try await database.write { tx throws(SQLiteError) in
    try tx.compareAndSet(table: "items", id: "a", expectedVersion: 1,
                         assignments: [SQLiteAssignment("body", .blob(newJSON))])
}

let body = try await database.read { tx throws(SQLiteError) in
    try tx.readBlob(table: "items", column: "body", keyColumn: "id", key: "a")
}

await database.close()
```

The DocC catalog has a full [Getting Started guide](Sources/SQLiteSwift/SQLiteSwift.docc/GettingStarted.md).
Build the documentation with `Scripts/build-docs.sh`.

## Conformance kit

`SQLiteSwiftTesting.SQLiteConformanceKit` runs 13 checks against your migrations
and configuration: migrations, schema-too-new refusal, compare-and-set conflict and
guard, commit failure while the transaction is open, commit outcomes and
resolution, busy contention, cancellation interrupt, deadlines and instruction
budgets, WAL checkpoint, recovery after an aborted mid-write crash image,
`SQLITE_FULL` via `max_page_count`, settings verification, and file identity.

```swift
@Test(arguments: SQLiteConformanceKit.Check.allCases)
func conformance(check: SQLiteConformanceKit.Check) async {
    let result = await SQLiteConformanceKit(migrations: MyStore.migrations).run(check)
    #expect(result.outcome == .passed, "\(result.notes)")
}
```

## Development

```sh
swift build
swift test
Scripts/verify-amalgamation.sh   # vendored SQLite is byte-identical to upstream
Scripts/build-docs.sh            # DocC, warnings are errors
```

Cross-compile for iOS:

```sh
swift build --build-tests --scratch-path .build/ios --triple arm64-apple-ios18.0 \
  --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
```

## Notes

- The module is named `SQLiteSwift`, not `SwiftSQLite`. macOS ships a private
  `/System/Library/PrivateFrameworks/SwiftSQLite.framework` that can be loaded into
  any process. Its Objective-C-visible classes (for example `SwiftSQLite.Connection`)
  clashed with this package under the old module name. Internal classes also keep an
  `SQLite` prefix.
- Apple's system SQLite keeps the `-wal` file after the last connection closes
  (truncated to 0 bytes). Linux deletes it.

See [ACCEPTANCE.md](ACCEPTANCE.md) for the 0.1.0 requirement-by-requirement evidence
and [ROADMAP.md](ROADMAP.md) for planned profiles and capabilities.
