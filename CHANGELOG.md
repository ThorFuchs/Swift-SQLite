# Changelog

## 0.9.0 — unreleased

Release candidate for 1.0.0: the API is frozen, and the repository is ready for
public use.

### Breaking changes

- `SQLitePredicate` is a struct instead of an enum, so operators can be added in 1.x.
  Predicates are built with the same spellings (`.equals`, `.notIn`, `.and`, …);
  only code that pattern-matched on predicate cases changes.
- `SQLiteError.isStop` is renamed `isInterruption`.

### Added

- `SQLiteSynchronous.extra` (`PRAGMA synchronous=EXTRA`).
- Community files: SECURITY.md (private vulnerability reporting), CONTRIBUTING.md,
  CODE_OF_CONDUCT.md, issue forms, a pull request template, CODEOWNERS.
- CI: Thread Sanitizer on macOS and Linux, Address Sanitizer on Linux, an API-breakage
  check against the latest release (`Scripts/check-api.sh`), a GitHub-hosted macOS
  job so pull requests from forks get macOS coverage, and Dependabot for GitHub
  Actions.
- `.spi.yml` for the Swift Package Index (documentation for both products).
- README for public use, with the versioning policy.

### Fixed

- SQLite is initialized once (`sqlite3_initialize()`) before connections open on
  several threads at the same time; SQLite's implicit initialization inside
  `sqlite3_open_v2` raced (found by ThreadSanitizer on Linux).
- Internal locks use `pthread_mutex_t`, which ThreadSanitizer sees on every platform,
  instead of `Synchronization.Mutex`, whose Linux futex lock it cannot see.
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
