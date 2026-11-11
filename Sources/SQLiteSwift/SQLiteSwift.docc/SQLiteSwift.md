# ``SQLiteSwift``

Durable, bounded SQLite persistence for Swift concurrency, with no package dependencies.

## Overview

SQLiteSwift is the shared SQLite base for domain stores such as MCP task stores
and content-collection stores. It provides the parts every store needs and none of
the domain logic:

- One writer connection (`BEGIN IMMEDIATE`) and a bounded pool of reader connections
  on WAL snapshot transactions. A single connection is also supported.
- Each connection runs its blocking SQLite calls on its own thread, which is joined on
  ``SQLiteDatabase/close()``. Nothing runs on the cooperative thread pool. There are
  no detached tasks and no global singletons.
- Writes return only after `COMMIT`. `synchronous=FULL` is the default;
  `NORMAL` is an explicit opt-in.
- A bounded busy timeout (5 seconds by default) ends in ``SQLiteError/busy(_:)``.
  Task cancellation calls `sqlite3_interrupt` and ends in ``SQLiteError/interrupted``.
- Forward-only migrations on `PRAGMA user_version`, one transaction each. A newer
  database is refused with ``SQLiteError/schemaTooNew(databaseVersion:supportedVersion:)``
  and left untouched.
- A compare-and-set helper that returns a conflict as a value, bounded reads, a
  bounded statement cache and an injectable clock for expiry queries.

On Apple platforms SQLiteSwift links the system SQLite. On Linux it compiles a
pinned, unmodified SQLite amalgamation.

## Topics

### Essentials

- <doc:GettingStarted>
- ``SQLiteDatabase``
- ``SQLiteConfiguration``
- ``SQLiteTransaction``

### Schema

- ``SQLiteMigration``

### Values and results

- ``SQLiteValue``
- ``SQLiteRow``
- ``SQLiteChanges``
- ``SQLiteValueKind``

### Limits

- ``SQLiteLimits``
- ``SQLiteQueryLimits``

### Helpers

- ``SQLiteCompareAndSetResult``
- ``SQLiteAssignment``
- ``SQLiteIdentifier``
- ``SQLiteTransactionOutcome``
- ``SQLiteCheckpointMode``
- ``SQLiteCheckpointResult``

### Time

- ``SQLiteClock``
- ``SQLiteSystemClock``
- ``SQLiteTimestamp``

### Durability and platform options

- ``SQLiteSynchronous``
- ``SQLiteFileProtection``

### Errors

- ``SQLiteError``
- ``SQLiteErrorDetails``
- ``SQLiteResultCode``
