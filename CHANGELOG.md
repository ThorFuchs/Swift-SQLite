# Changelog

## Unreleased

- CI: the macOS job on the self-hosted runner no longer runs for pull requests from
  forks, now that the repository is public. Linux CI still runs for them.

## 0.1.0 — 2026-11-12

- Module names: `SQLiteSwift` (library), `SQLiteSwiftTesting` (test kit), `CSQLiteSwift`
  (Linux C target). Not `SwiftSQLite`, which clashes with a private Apple framework.
- `SQLiteSwift`: `SQLiteDatabase` with one `BEGIN IMMEDIATE` writer and a bounded
  reader pool on WAL snapshot transactions, or a single connection. Each connection
  has a dedicated thread, joined on `close()`.
- `synchronous=FULL` by default, `NORMAL` as opt-in; writes return after `COMMIT`.
  On Apple platforms `fullfsync` and `checkpoint_fullfsync` are on by default
  (`appleFullFSync`). Every applied setting is read back at open
  (`SQLiteError.settingMismatch`); `effectiveSettings()` reports them.
- Truthful commit errors: `SQLiteError.commitOutcomeUnknown` when `COMMIT` failed after
  the transaction ended; every other thrown error means "not committed".
- Typed `.cantOpen` and `.ioError` (extended code); a non-writable database file fails
  at open with `.readOnly`.
- Guarded compare-and-set (`alsoRequire:` with typed, bound `SQLitePredicate`) and
  `.guardFailed(currentVersion:)`; keyset pagination with `queryPage`.
- Bounded busy handler (default 5 s) → `SQLiteError.busy`; task cancellation →
  `sqlite3_interrupt` → `SQLiteError.interrupted`.
- Forward-only `user_version` migrations, one transaction each; newer databases are
  refused untouched with `.schemaTooNew`.
- Compare-and-set helper with typed `.updated` / `.conflict` / `.notFound` results;
  `writeOrRollback` for rolling back with a value.
- Bounded reads: per-query row limits and byte budgets (1 MiB default, 16 MiB hard cap,
  also `SQLITE_LIMIT_LENGTH`), `readBlob` with a `length(col)` pre-check, bounded LRU
  prepared-statement cache.
- Injectable `SQLiteClock`; expiry helpers `deleteExpired`, `countExpired`, `deadline`.
- WAL checkpoints (passive, full, restart, truncate).
- Optional iOS data-protection class.
- `SQLiteSwiftTesting`: `SQLiteConformanceKit` (9 checks), `SQLiteManualClock`,
  `SQLiteTemporaryDirectory`, `SQLiteTestLatch`, `SQLiteCrashImage`.
- Linux: pinned, unmodified SQLite 3.54.1 amalgamation with provenance and SHA-256
  verification. Apple platforms use the system SQLite.
