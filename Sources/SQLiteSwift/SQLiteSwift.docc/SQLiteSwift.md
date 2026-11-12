# ``SQLiteSwift``

Durable, bounded SQLite persistence for Swift concurrency, with no package dependencies.

## Overview

SQLiteSwift is a foundation for persistent stores built on SQLite, such as task
queues, caches, document and content stores. It provides the parts every store needs
and none of the domain logic:

- One writer connection (`BEGIN IMMEDIATE`) and a bounded pool of reader connections
  on WAL snapshot transactions. A single connection is also supported.
- Each connection runs its blocking SQLite calls on its own thread, which is joined on
  ``SQLiteDatabase/close()``. Nothing runs on the cooperative thread pool. There are
  no detached tasks and no global singletons.
- Writes return only after `COMMIT`. `synchronous=FULL` is the default;
  `NORMAL` is an explicit opt-in.
- A bounded busy timeout (5 seconds by default) ends in ``SQLiteError/Code/busy``.
  Task cancellation calls `sqlite3_interrupt` and ends in ``SQLiteError/Code/interrupted``.
  Per-operation deadlines and instruction budgets stop runaway work.
- Truthful commit outcomes: a thrown error means "not committed", except
  ``SQLiteError/Code/commitOutcomeUnknown``, which ``SQLiteDatabase/resolveCommit(limits:_:)``
  decides with a fresh read.
- Forward-only migrations on `PRAGMA user_version`, one transaction each. A newer
  database is refused with ``SQLiteError/Code/schemaTooNew`` and left untouched. A
  ``SQLiteFileIdentity`` keeps you from opening the wrong file.
- A compare-and-set helper that returns a conflict as a value, keyset pagination,
  bounded and byte-exact reads, a bounded statement cache and an injectable clock for
  expiry queries.

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
- ``SQLiteFileIdentity``
- ``SQLiteAutoVacuum``

### Values and results

- ``SQLiteValue``
- ``SQLiteRow``
- ``SQLiteChanges``
- ``SQLiteValueKind``
- ``SQLiteRawValue``
- ``SQLiteRawRow``

### Limits

- ``SQLiteLimits``
- ``SQLiteQueryLimits``
- ``SQLiteOperationLimits``

### Helpers

- ``SQLiteCompareAndSetResult``
- ``SQLitePredicate``
- ``SQLiteKeysetCursor``
- ``SQLiteKeysetPage``
- ``SQLiteAssignment``
- ``SQLiteIdentifier``
- ``SQLiteTransactionOutcome``
- ``SQLiteCommitOutcome``
- ``SQLiteCheckpointMode``
- ``SQLiteCheckpointResult``

### Time

- ``SQLiteClock``
- ``SQLiteSystemClock``
- ``SQLiteTimestamp``

### Durability and platform options

- ``SQLiteEffectiveSettings``
- ``SQLiteSynchronous``
- ``SQLiteFileProtection``

### Errors

- ``SQLiteError``
- ``SQLiteErrorDetails``
- ``SQLiteResultCode``
