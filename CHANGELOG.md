# Changelog

## Unreleased

### Added

- Backups and maintenance: `backup(to:pagesPerStep:limits:progress:)` copies the
  database from one read snapshot with `sqlite3_backup`, in steps that honor
  deadlines and cancellation; `vacuum(into:limits:)` writes a compacted snapshot
  without occupying the writer; `integrityCheck(maxProblems:limits:)` and
  `quickCheck(maxProblems:limits:)` return a typed `SQLiteIntegrityReport`;
  `optimize(limits:)` and `incrementalVacuum(pages:limits:)`. Destinations are never
  overwritten, and a stopped or failed copy leaves no file.
- Observation hooks: `SQLiteConfiguration.observer` takes an `SQLiteObserver`
  that sees every operation (`SQLiteOperation.Kind`: read, write, resolve_commit,
  checkpoint, backup, vacuum_into, integrity and quick checks, optimize,
  incremental vacuum) with the wait for a connection, the duration and the outcome
  (succeeded, rolled back, failed). Both callbacks run on the calling task, so
  task-local context (tracing, logging) is available. No observer, no cost.
- Fault injection for consumers: `SQLiteSwiftTesting` adds
  `SQLiteDatabase.injectFault(_:)` with `SQLiteFault.commitOutcomeUnknown`, so a
  store can test its handling of an unknown commit with a real failing `COMMIT`.
- Server bridges (`SQLiteSwiftServer`), each behind an opt-in package trait so the
  default dependency graph stays empty: `SQLiteMetricsObserver` (trait `Metrics`,
  swift-metrics: operation duration, connection wait, error counts with bounded
  dimensions), `SQLiteTracingObserver` (trait `Tracing`, swift-distributed-tracing:
  a client span per operation, nested under the caller's span, errors recorded),
  `SQLiteLoggingObserver` (trait `Logging`, swift-log, `Logger.current` by default),
  `SQLiteDatabaseService` (trait `ServiceLifecycle`: closes the database on graceful
  shutdown, optional scheduled checkpoint and optimize). `SQLiteObservers` combines
  several observers.
- Migration checksums (opt-in): `SQLiteConfiguration.verifiesMigrationChecksums`
  records each applied migration's `checksum` (FNV-1a 64 of version, name and SQL)
  in `sqliteswift_migration_checksums` and refuses a file whose applied migrations
  changed (`SQLiteError.Code.migrationModified`) before any new migration runs.
  Existing files are adopted, not refused.
- SQLite release watch: `Scripts/check-sqlite-release.sh` and a weekly workflow that
  opens an issue (once per release) when sqlite.org publishes a newer amalgamation.
- FTS5 full-text search on Linux (the vendored engine is compiled with
  `SQLITE_ENABLE_FTS5`), matching Apple's system SQLite.

### Changed

- Developer kit 0.2.0: pinned to library 1.0.0 (tag, commit and tree in its
  compatibility map); new integrations use `from: "1.0.0"`; the version reference
  lists 1.0.0. All 13 recipes pass against the published 1.0.0 tag.

## 1.0.0 — 2026-11-15

The first stable release. The public API is the one frozen in 0.9.0, unchanged:
from now on, only a major release may break source compatibility. 0.9.0 was
validated downstream by Swift-MCP-Server-Core (build, its task-store tests and the
conformance kit, also under ThreadSanitizer) with nothing changed but its version
pin.

Upgrading from 0.9.0: change the requirement to `from: "1.0.0"`; no code changes.

### Documentation

- ROADMAP: the plan after 1.0.0 — 1.1.0 operates it on a server, 1.2.0 brings
  the model layer to servers, profiles follow by demand; a modern-Swift watch list
  and clearer non-goals.

### Added

- A dependency-free benchmark package (`Benchmarks/`, `Scripts/run-benchmarks.sh`)
  and a recorded baseline for 1.0.0 (`Documentation/Benchmarks.md`).
- CI: the GitHub-hosted macOS job also runs the tests with the Swift 6.2 upcoming
  feature `NonisolatedNonsendingByDefault` (SE-0461); all tests pass with it.
- Developer kit 0.1.0 for coding agents, pinned to library 0.9.0: an
  instruction-only `swift-sqlite` skill (Claude Code plugin marketplace and the
  portable Agent Plugins format) with references and 13 recipes compiled and run
  from one consumer package. `Scripts/validate_developer_kit.py`,
  `Scripts/run_kit_recipes.sh` and `Scripts/package_developer_kit.py`; CI validates
  the kit and runs every recipe against each pull request. The library is unchanged.
- `AGENTS.md` for contributors.
- `NOTICE` file (Apache-2.0); SPDX headers on every source, script and workflow
  file.

### Changed

- README: release, Swift and platform badges, an overview of the four products and
  the developer kit, when the package fits and when not, and the protected `main`.
- CONTRIBUTING, SECURITY, the bug report form (a product field) and the pull
  request template cover the model layer and the developer kit.
- The observable-context research spike is marked as historical and points to the
  shipped model layer.

## 0.9.0 — 2026-11-15

Release candidate for 1.0.0: the API is frozen, and the repository is ready for
public use.

### Breaking changes

- `SQLitePredicate` is a struct instead of an enum, so operators can be added in 1.x.
  Predicates are built with the same spellings (`.equals`, `.notIn`, `.and`, …);
  only code that pattern-matched on predicate cases changes.
- `SQLiteError.isStop` is renamed `isInterruption`.

### Added

- Opt-in model layer, two new products (design and evidence:
  `Documentation/MODEL-ARCHITECTURE.md`):
  - `SQLiteSwiftModels`: `SQLiteRecord` with `SQLiteRecordDescriptor` and typed
    `SQLiteColumn`s; strict `SQLiteCodec`s (text, BLOB, integer, Int, Bool, REAL,
    decimal text, UUID as text or BLOB, timestamp, Unix milliseconds, optional,
    raw-value enums); `SQLiteRecordSnapshot` with `SQLiteRecordVersion` (revision
    plus a random incarnation, so a reused key never matches an old version);
    `fetch`, `fetchAll` and `verifySchema`; conditional `insert`, `update`,
    `save(_:expecting:)` and `delete` returning `SQLiteRecordWriteOutcome`
    (`inserted`, `updated`, `deleted`, `conflict(current:)`, `missing`);
    all-or-nothing batches (`SQLiteDatabase.writeRecords(_:)`); `SQLiteModelStore`
    with a committed-change stream (snapshot handoff without gaps, bounded buffers
    ending in `resyncRequired`); `SQLiteModelSchema` for the store's tables.
  - `SQLiteSwiftModelContext`: main-actor `SQLiteModelContext` with one
    `@Observable` `SQLiteModel` handle per record (`clean`, `dirty`, `saving`,
    `conflicted`, `deleted`, `indeterminate`), atomic conditional `save()`, explicit
    `useRemote`, `keepLocal` and `discard`, `resolveIndeterminate()` for unknown
    commit outcomes, `observeChanges()` for live handles, and `SQLiteLiveQuery`.
  - DocC catalogs and guides for both; `Scripts/build-docs.sh` builds every module.
- `SQLiteError.Code.schemaMismatch` and `.invalidStoredValue` (with
  `SQLiteError.column`), used by the model layer.
- `SQLiteSynchronous.extra` (`PRAGMA synchronous=EXTRA`).
- Community files: SECURITY.md (private vulnerability reporting), CONTRIBUTING.md,
  CODE_OF_CONDUCT.md, issue forms, a pull request template, CODEOWNERS.
- CI: Thread Sanitizer on macOS and Linux, Address Sanitizer on Linux, an API-breakage
  check against the latest release (`Scripts/check-api.sh`), a GitHub-hosted macOS
  job so pull requests from forks get macOS coverage, and Dependabot for GitHub
  Actions.
- `.spi.yml` for the Swift Package Index (documentation for every product).
- README for public use, with the versioning policy.

### Fixed

- SQLite is initialized once (`sqlite3_initialize()`) before connections open on
  several threads at the same time; SQLite's implicit initialization inside
  `sqlite3_open_v2` raced (found by ThreadSanitizer on Linux).
- Internal locks use `pthread_mutex_t`, which ThreadSanitizer sees on every platform,
  instead of `Synchronization.Mutex`, whose Linux futex lock it cannot see.
- Tests: the concurrency gauge uses `SQLiteLocked` instead of `Mutex`, which
  ThreadSanitizer on Linux reported as a race under contention.
- CI: Linux ThreadSanitizer runs with ASLR disabled; the one remaining known-benign
  SQLite report and the XCTest runner's exit-time leaks are suppressed with reasons.

### Changed

- Enums that will never gain cases say so in their documentation.
- The 0.1.0 acceptance record moved to `Documentation/Acceptance-0.1.0.md`.

## 0.2.0 — 2026-11-12

Truthful and bounded. This release changes the error and conformance-kit APIs so
that later releases can add error codes and checks without breaking callers; see
"Migrating from 0.1.0".

### Breaking changes

- `SQLiteError` is a struct instead of an enum. Match on `error.code`
  (`SQLiteError.Code`, a struct with static members) with a `default` branch, or
  catch by code: `catch SQLiteError.Code.busy { … }`. Detail moved to typed
  accessors: `details`, `underlying`, `reason`, `limit`, `databaseVersion` and
  `supportedVersion`, `migrationVersion` and `migrationName`, `typeMismatch`,
  `setting`. Static factories keep the old construction spellings
  (`.invalidArgument("…")`, `.schemaTooNew(databaseVersion:supportedVersion:)`).
- `SQLiteConformanceKit.Check` is a struct instead of an enum. `allCases` and the
  static names are unchanged; `rawValue` is now `name`; a `switch` needs a `default`.

### Added

- Operation limits: `SQLiteOperationLimits(timeout:maxInstructions:)` per call
  (`read(limits:)`, `write(limits:)`, `writeOrRollback(limits:)`) or for the whole
  database (`SQLiteConfiguration.operationLimits`). Deadlines also bound the wait
  for a connection and for locks. New codes `.deadlineExceeded` and
  `.instructionLimitExceeded`; the first cause (cancellation, deadline, budget) is
  reported, and a stop never reaches the next operation on the connection.
- Commit outcomes: `SQLiteCommitOutcome` (`.committed`, `.notCommitted`, `.unknown`)
  from `writeReportingOutcome(limits:_:)`, and `resolveCommit(limits:_:)`, which
  decides an unknown outcome on a fresh read-only connection.
- Raw rows: `SQLiteRawValue` and `SQLiteRawRow` keep TEXT as its exact stored bytes
  (invalid UTF-8 and embedded NUL included); `queryRaw(_:_:limits:)` and
  `executeRaw(_:_:)`.
- File identity: `SQLiteFileIdentity` (`application_id`, optional `page_size` and
  `auto_vacuum`) is written to new files and checked on existing ones; a mismatch
  throws `.fileIdentityMismatch` without writing. `adoptsUnmarkedFiles` marks files
  created before an identity was adopted. `SQLiteAutoVacuum`.
- `effectiveSettings()` also reports `applicationID`, `pageSize`, `autoVacuum`,
  `mmapSize`, `maxLength` (`SQLITE_LIMIT_LENGTH`) and `compileOptions`.
- Conformance kit: checks `commitOutcome`, `operationLimits`, `settingsVerification`
  and `fileIdentity` (13 checks).

### Fixed

- Column reads call `sqlite3_column_text`/`sqlite3_column_blob` before
  `sqlite3_column_bytes`, as SQLite documents.
- `Scripts/build-docs.sh` finds `docc` in the active Xcode toolchain when it isn't on
  `PATH`.
- CI: the macOS job on the self-hosted runner no longer runs for pull requests from
  forks, now that the repository is public. Linux CI still runs for them.

### Migrating from 0.1.0

| 0.1.0 | 0.2.0 |
| --- | --- |
| `catch SQLiteError.busy(let d)` | `catch let e as SQLiteError where e.code == .busy` (detail: `e.details`) |
| `catch SQLiteError.commitOutcomeUnknown(_)` | `catch SQLiteError.Code.commitOutcomeUnknown` |
| `guard case .constraint(let d) = error` | `guard error.code == .constraint, let d = error.details` |
| `case .schemaTooNew(let found, let supported)` | `error.databaseVersion`, `error.supportedVersion` |
| `case .migrationFailed(let v, let name, let underlying)` | `error.migrationVersion`, `error.migrationName`, `error.underlying` |
| `case .settingMismatch(let s, let e, let a)` | `error.setting?.name`, `.expected`, `.actual` |
| `switch error { case .busy: … }` | `switch error.code { case .busy: … default: … }` |
| `SQLiteConformanceKit.Check.x.rawValue` | `.name` |

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
