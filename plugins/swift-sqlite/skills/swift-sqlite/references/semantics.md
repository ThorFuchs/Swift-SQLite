# Semantics and limits

## Connections and threads

One writer connection (`BEGIN IMMEDIATE`) and a bounded pool of readers (default 4)
on WAL snapshots; `readerCount = 0` is a single connection, required for in-memory
databases. Each connection runs SQLite on its own thread, never on the cooperative
pool. `close()` lets running work finish, fails waiting work with `.closed`, and
joins the threads. Always `await database.close()` when done.

## Transactions

- `write { tx throws(SQLiteError) in … }` commits when the closure returns and rolls
  back when it throws. `writeOrRollback` lets the closure return `.commit(value)` or
  `.rollback(value)` to keep a domain outcome while discarding changes.
- `read` runs a deferred transaction: every statement sees the same snapshot.
  Statements that write throw `readOnly`.
- The closure is synchronous. Do the async work before or after it.

## Errors

`SQLiteError.code` is an extensible struct. Common codes: `busy` (lock wait
exceeded the busy timeout, default 5 s), `interrupted` (task cancelled),
`deadlineExceeded`, `instructionLimitExceeded`, `constraint`, `rowLimitExceeded`,
`resultTooLarge`, `schemaTooNew`, `fileIdentityMismatch`, `settingMismatch`,
`commitOutcomeUnknown`, `closed`, `invalidArgument`, `misuse`. Always keep a
`default` branch.

## Commit outcomes

A thrown write did not commit, except `commitOutcomeUnknown`: `COMMIT` was issued,
failed, and the transaction ended. Write a key chosen before the write, then call
`resolveCommit { tx in … }`, which reads on a fresh connection. Reply only after it
decides. `writeReportingOutcome` returns `.committed`, `.notCommitted` or `.unknown`.

## Limits

Queries have row limits (default 10,000) and byte budgets (1 MiB default, 16 MiB
hard cap). Results are never silently truncated. `SQLiteOperationLimits(timeout:,
maxInstructions:)` bound a call, including the wait for a connection. Choose finite
values from the task; don't disable limits to make inputs pass.

## Model layer

- Codecs convert exactly or throw `invalidStoredValue` naming the column.
- Versions: `revision` (≥ 1, +1 per update, never wraps; `Int64.max` throws) and a
  16-byte random `incarnation` per inserted row.
- Write outcomes: `inserted`, `updated`, `deleted`, `conflict(current:)`, `missing`.
  Busy, deadline, cancellation and constraint violations stay errors.
- `SQLiteModelStore.subscribe` registers first, then reads the snapshot and the
  sequence together: nothing is lost or duplicated between snapshot and stream.
  A full buffer or an unknown commit sends `resyncRequired`; subscribe again.
- `SQLiteModelContext` is `@MainActor`. States: `clean`, `dirty`, `saving`,
  `conflicted`, `deleted`, `indeterminate`. Saves are atomic and conditional; a
  second save waits for the first. `indeterminate` blocks saves until
  `resolveIndeterminate()`.
