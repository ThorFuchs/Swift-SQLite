# Changelog

## 0.1.0 — candidate (unreleased, untagged)

- `SwiftSQLite`: `SQLiteDatabase` with one `BEGIN IMMEDIATE` writer and a bounded
  reader pool on WAL snapshot transactions, or a single connection. Each connection
  has a dedicated thread, joined on `close()`.
- `synchronous=FULL` by default, `NORMAL` as opt-in; writes return after `COMMIT`.
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
- `SwiftSQLiteTesting`: `SQLiteConformanceKit` (8 checks), `SQLiteManualClock`,
  `SQLiteTemporaryDirectory`, `SQLiteTestLatch`, `SQLiteCrashImage`.
- Linux: pinned, unmodified SQLite 3.54.1 amalgamation with provenance and SHA-256
  verification. Apple platforms use the system SQLite.
