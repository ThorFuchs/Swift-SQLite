# Swift-SQLite 0.1.0 — acceptance report

Candidate for acceptance review, prepared 2026-11-11. Not tagged, not released.

- **Source verified:** branch `swift-sqlite-0.1.0` at commit `68d64ff`
  (`68d64ffc2c4f3b250e131605702cc0776c115c61`). The only later commit adds this file.
- **Spec:** `swift-sqlite-requirements.md` (MCP-Server session, ADR-0004 Tasks phase C)
  plus the task brief from the Swift-JSON session.
- **Machine:** macOS (Darwin 27.3, arm64). Swift 6.4.2 via swiftly
  (`TOOLCHAINS=org.swift.642202610261a`), Xcode 27.2 SDKs (macOS 27.2, iOS 27.2).
  System SQLite 3.54.0 on macOS/iOS; vendored 3.54.1 on Linux.

## Summary

| Platform | What ran | Result |
| --- | --- | --- |
| macOS (arm64) | `swift test`, 3 consecutive runs plus 1 final run | **45 tests / 90 test cases in 6 suites passed**, exit 0 every run, 0 warnings |
| iOS simulator (iOS 27.2 runtime, iPhone 17 Pro, deployment target 18.0) | `xcodebuild test` | **45 tests in 6 suites passed**, `TEST SUCCEEDED`, exit 0 |
| iOS device `arm64-apple-ios18.0` | cross-compile incl. tests | exit 0 |
| iOS simulator `arm64-apple-ios18.0-simulator` | cross-compile incl. tests | exit 0 |
| Linux (musl, Static Linux SDK 6.4.0, aarch64 + x86_64) | cross-compile and link of both library products; a static executable that runs the conformance kit was linked | exit 0; **tests not executed on Linux** (see "Not run") |
| Linux (Ubuntu 24.04, Swift 6.4.0 container) | `.github/workflows/linux.yml` | **Not run locally.** Runs on the PR; result to be read there |
| DocC | `Scripts/build-docs.sh` (`--warnings-as-errors`) | exit 0 |
| Amalgamation integrity | `Scripts/verify-amalgamation.sh` | exit 0, both SHA-256 match |

"Tests" counts `@Test` functions. "Test cases" also counts each argument of the
8 parameterized tests (37 plain + 53 parameterized cases = 90). The xunit report
lists 45 `<testcase>` entries, one per test function.

## Requirement → evidence

Test names are the `@Test` display names. The `Conformance kit` suite runs every
`SQLiteConformanceKit` check under five configurations: default pool, single
connection, `synchronous=NORMAL` with 2 readers and no statement cache, no consumer
migrations, and in-memory.

### Names, platforms, toolchain

| Requirement | Evidence |
| --- | --- |
| Repository `Swift-SQLite`; product/module `SQLiteSwift`; test kit `SQLiteSwiftTesting`; no module named `SQLite` | `Package.swift` (products `SQLiteSwift`, `SQLiteSwiftTesting`; C module `CSQLiteSwift`) |
| macOS 15, iOS 18, Linux | `Package.swift` `platforms: [.macOS(.v15), .iOS(.v18)]`; iOS cross-compiles and simulator run; Linux musl cross-compile; `linux.yml` |
| Swift tools 6.4, language mode 6, strict concurrency | `Package.swift` (`swift-tools-version: 6.4`, `.swiftLanguageMode(.v6)` on every Swift target). Builds with 0 warnings |
| Zero package dependencies | `Package.swift` has no `dependencies:`. Only toolchain modules are used: `Synchronization`, libc, and `Foundation` in `SQLiteSwiftTesting` only |

### SQLite source

| Requirement | Evidence |
| --- | --- |
| System SQLite on Apple platforms | `Sources/SQLiteSwift/**`: `#if os(Linux) internal import CSQLiteSwift #else internal import SQLite3`; `CSQLiteSwift` is a dependency only `.when(platforms: [.linux])`; `shim.c` compiles nothing outside `__linux__` |
| Linux: pinned, unmodified amalgamation in a C target | `Sources/CSQLiteSwift/sqlite3.c`, `include/sqlite3.h` (3.54.1). `Scripts/verify-amalgamation.sh` passes; it also runs in both CI workflows. The Linux object exports 266 `sqlite3_*` functions |
| Provenance file (version, URL, SHA-256, public-domain notice) | `Sources/CSQLiteSwift/PROVENANCE.md` (also the archive SHA3-256, which was checked against sqlite.org); `THIRD_PARTY_NOTICES.md` |
| Only `cSettings` defines, no `unsafeFlags` | `Package.swift` (`amalgamationDefines`, Linux-only `.define`s; `linkedLibrary("pthread")` and `("m")`). `unsafeFlags` appears in `Package.swift` only in a comment saying it is not used |

### Connections and threads

| Requirement | Evidence |
| --- | --- |
| One writer using `BEGIN IMMEDIATE` | `SQLiteDatabase.writeOrRollback` (`BEGIN IMMEDIATE` on the writer behind a 1-slot pool). Tests: *Writes are serialized on the single writer*; conformance `busyContention` |
| Bounded reader pool (default 4) on WAL snapshot transactions | `SQLiteConfiguration.readerCount = 4`, `SQLiteSlotPool`; reads use `BEGIN DEFERRED` on read-only, `query_only` connections. Tests: *The reader pool bounds concurrent reads* (0, 1, 4 readers); *A read transaction keeps one WAL snapshot while a write commits*; *Default busy timeout is 5 seconds* (also checks the defaults) |
| Single connection configurable | `SQLiteConfiguration.singleConnection(path:)` / `readerCount = 0`; `.inMemory()`. Conformance suite "Single connection" (8 cases); reader-pool test with 0 readers |
| Dedicated thread per connection, never the cooperative pool | `Internal/WorkerThread.swift` (one pthread per connection, FIFO jobs); `SQLiteConnection.run` bridges with a continuation. Test: *Closures run on dedicated named threads, not the cooperative pool* (thread names `sqliteswift.w` / `sqliteswift.rN`) |
| Thread joined on close | `SQLiteWorkerThread.stopAndJoin()` (`pthread_join`); `SQLiteDatabase.close()`. Tests: *close() joins every worker thread; later calls throw .closed; close is idempotent*; *close() waits for running operations to finish* |
| No detached tasks, no global singletons | `grep -rn "Task.detached\|static var\|static let shared" Sources/SQLiteSwift Sources/SQLiteSwiftTesting` finds nothing. Global state is limited to C callback functions without storage |

### Durability

| Requirement | Evidence |
| --- | --- |
| Writes return only after commit | `writeOrRollback` returns after `COMMIT` succeeds; a failed commit rolls back and throws. Test: *A write is visible to another database instance as soon as it returns* (20 iterations, separate instance) |
| `synchronous=FULL` default; `NORMAL` only as opt-in | `SQLiteConfiguration.synchronous = .full`, applied to the writer and every reader. Tests: *Pragmas: WAL, synchronous=FULL by default, …* (writer and reader read `2`); *synchronous=NORMAL is an explicit opt-in* (`1`) |
| Bounded busy timeout (~5 s) → typed `.busy` | Own busy handler `SQLiteConnectionCore.onBusy` (backoff, deadline from `busyTimeout`, default 5 s, validated ≤ 600 s). Tests: *Busy timeout is bounded and yields typed .busy*; conformance `busyContention` (300 ms timeout, observed about 0.30 s) |
| Task cancellation → `sqlite3_interrupt` → typed error | `SQLiteConnection.run` cancel handler: sets the job flag and calls `sqlite3_interrupt`, but only on the job that is still running. Statement boundaries and the busy handler check the flag. Error: `SQLiteError.interrupted`, after a rollback. Tests: conformance `cancellationInterrupt` (running read, running write that rolls back, pre-cancelled task); *Cancelling a task waiting for a busy writer slot throws .interrupted promptly*; *Cancellation during a busy wait ends the wait early with .interrupted* (30 s timeout, ends in < 2 s) |

### Helpers

| Requirement | Evidence |
| --- | --- |
| CAS `UPDATE … SET version = version + 1 WHERE id = ? AND version = ?` with a typed conflict | `SQLiteTransaction.compareAndSet` → `SQLiteCompareAndSetResult` (`.updated`, `.conflict(currentVersion:)`, `.notFound`). Tests: *Compare-and-set: updated, conflict, notFound; arguments validated*; *A CAS conflict can roll back the rest of the transaction*; conformance `compareAndSetConflict` (8 concurrent writers: exactly 1 updates, 7 conflict) |
| Injectable clock; no direct wall-clock reads in expiry helpers | `SQLiteClock`, `SQLiteConfiguration.clock`; `now()`, `deadline(after:)`, `deleteExpired`, `countExpired` read only `clock.now()`. The only wall-clock read is `SQLiteSystemClock`. Busy timing uses the monotonic `ContinuousClock`. Tests: *Expiry helpers use the injected clock only* (`SQLiteManualClock`); *Timestamps advance and saturate* |

### Bounded reads

| Requirement | Evidence |
| --- | --- |
| Check BLOB size with `length(col)` before loading | `SQLiteTransaction.readBlob` (runs `SELECT length(col)` first, then loads). Test: *readBlob checks length(column) before loading the value* (a 2 MB value is refused under the 1 MiB default, allowed with an explicit 2 MB budget; NULL, a missing row and identifier injection are covered) |
| Configurable per-query row limits | `SQLiteQueryLimits.maxRows`, `SQLiteLimits.defaultMaxRows` (10,000). Errors, never truncation. Test: *Row limits: configured default and per query; never silently truncated* |
| Bounded prepared-statement cache | `Internal/StatementCache.swift` (LRU, finalizes on eviction, capacity 0…1024, default 32). Test: *The prepared-statement cache is bounded* (capacities 0 and 4 with 20 distinct statements) |
| Sizes from configuration (1 MiB default, 16 MiB hard cap) | `SQLiteLimits` (`defaultMaxResultBytes = 1 MiB`, `hardMaxResultBytes = 16 MiB`, also set as `SQLITE_LIMIT_LENGTH` and enforced on bound values). Tests: *Default limits: …*; *Byte budgets: default, per query, and the hard cap* |

### Migrations

| Requirement | Evidence |
| --- | --- |
| `user_version`, forward-only, one transaction per migration | `SQLiteMigration`, `SQLiteConnectionCore.migrate` (one `BEGIN IMMEDIATE` per migration; sets `user_version` inside it; re-checks the version under the lock; versions must be `1…n` with no gaps). Tests: *Migrations set user_version and run once each*; *Migration failure carries version, name and the underlying typed error*; *Invalid configurations are refused before opening* (gap); conformance `migrations` (once only, reopen runs 0, partial upgrade runs 1, a failing migration rolls back alone) |
| A database newer than the code is refused with a typed error and left untouched | The version check runs before any write, including the switch to WAL. `SQLiteError.schemaTooNew(databaseVersion:supportedVersion:)`. Tests: *A newer schema is refused without touching the file, also from a pending WAL* (byte-identical file); *A rollback-journal database newer than the code is not switched to WAL* (header bytes 18/19 stay 1); conformance `schemaTooNew` |

### Typed errors

| Requirement | Evidence |
| --- | --- |
| busy, constraint, corrupt, full, interrupted, schemaTooNew, plus a wrapper for other codes | `SQLiteError` cases `.busy`, `.constraint`, `.corrupt` (also `NOTADB`), `.full`, `.interrupted`, `.schemaTooNew`, `.sqlite(SQLiteErrorDetails)`, plus `.readOnly`, `.tooBig`, `.resultTooLarge`, `.rowLimitExceeded`, `.typeMismatch`, `.closed`, `.invalidConfiguration`, `.invalidArgument`, `.misuse`, `.migrationFailed`. Extended result codes are kept. Tests: *Result codes map to typed errors*; *Typed constraint errors keep the extended result code* (2067 UNIQUE, 787 FOREIGNKEY); *A file that isn't a database is reported as corrupt* |
| SQLITE_FULL | Conformance `diskFull` (`max_page_count` → `.full(code 13)`, rollback, database stays usable), in all five conformance configurations |

### iOS

| Requirement | Evidence |
| --- | --- |
| Optional file-protection class | `SQLiteConfiguration.fileProtection` → `SQLITE_OPEN_FILEPROTECTION_*` open flags (`#if os(iOS)`). Test: *File-protection classes map to Apple's SQLITE_OPEN_FILEPROTECTION_\* values*. On the iOS simulator run the flag is asserted to be set; on macOS it is asserted to be ignored |

### Out of scope (confirmed)

No task stores, leases or content generations. No Swift-JSON dependency: consumers
bind canonical JSON bytes as `SQLiteValue.blob`.

## Conformance kit (deliverable 2)

`SQLiteConformanceKit` (`Sources/SQLiteSwiftTesting/SQLiteConformanceKit.swift`) is
generic. A consumer passes its own migrations and a configuration factory. Each
check uses a fresh temporary directory and `sqliteswift_probe*` tables only.

| Check | What it proves | Observed (macOS, default configuration) |
| --- | --- | --- |
| `migrations` | Applied once, in order; reopen runs none; partial upgrade runs the rest; a failing migration rolls back alone | passed |
| `schemaTooNew` | Newer database refused; file byte-identical; no WAL left behind | passed (8192 bytes unchanged) |
| `compareAndSetConflict` | updated, conflict, notFound; 8 concurrent CAS → 1 winner | passed |
| `busyContention` | Second database on the same file → `.busy` after its timeout; retry succeeds | passed (about 0.30 s for a 0.3 s timeout) |
| `cancellationInterrupt` | Running read/write interrupted; the write rolls back; pre-cancelled task never starts; database usable | passed (read stopped within milliseconds) |
| `walCheckpoint` | Passive checkpoint copies all frames; truncate empties the WAL | passed (71 frames, WAL → 0 bytes) |
| `recoveryAfterAbortedWrite` | Crash image taken mid-transaction (uncommitted frames required in the WAL, `-shm` dropped) recovers the 10 committed rows; integrity ok | passed (1,289,592 WAL bytes at the crash point) |
| `diskFull` | `max_page_count` → `.full`; rollback; later writes succeed | passed |

The kit also provides `SQLiteManualClock`, `SQLiteTemporaryDirectory`,
`SQLiteTestLatch` and `SQLiteCrashImage`.

## Exact commands and outcomes

Environment for every command (from the repository root):

```sh
set -a; . ~/.swiftly/env.sh; set +a
export TOOLCHAINS=org.swift.642202610261a SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
hash -r
```

| # | Command | Exit | Outcome |
| --- | --- | --- | --- |
| 1 | `Scripts/verify-amalgamation.sh` | 0 | `sqlite3.c` and `sqlite3.h` SHA-256 match |
| 2 | `swift build --build-tests` | 0 | 0 warnings outside `sqlite3.c` |
| 3 | `swift build -c release --scratch-path .build/release-check` | 0 | |
| 4 | `swift test --xunit-output …` (runs 1, 2, 3) | 0, 0, 0 | 45 tests in 6 suites passed (1.70 s, 1.00 s, 1.17 s) |
| 5 | `swift test --xunit-output …` (final, after the warning cleanup) | 0 | 45 tests / 90 cases passed, 0 warnings |
| 6 | `SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) swift build --build-tests --scratch-path .build/ios --triple arm64-apple-ios18.0 --sdk "$SDKROOT"` | 0 | |
| 7 | `SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) swift build --build-tests --scratch-path .build/iossim --triple arm64-apple-ios18.0-simulator --sdk "$SDKROOT"` | 0 | |
| 8 | `xcodebuild -scheme Swift-SQLite-Package -destination "id=<iPhone 17 Pro, iOS 27.2 simulator>" -derivedDataPath .build/xcode test` | 0 | `TEST SUCCEEDED`, 45 tests in 6 suites passed (7.9 s) |
| 9 | `Scripts/build-docs.sh` | 0 | DocC archive built with `--warnings-as-errors` |
| 10 | `swift build --scratch-path .build/linux --swift-sdk swift-6.4.0-RELEASE_static-linux-0.1.0 --triple aarch64-swift-linux-musl` (`SDKROOT` unset) | 0 | |
| 11 | Same with `--triple x86_64-swift-linux-musl` | 0 | |
| 12 | Scratch package linking `SQLiteSwift` + `SQLiteSwiftTesting` into a static `x86_64-swift-linux-musl` executable that runs `SQLiteConformanceKit().runAll()` | 0 | ELF 64-bit static executable linked (not executed); the same program run on macOS printed `ALL PASSED` |

## Not run, and open points

1. **Linux tests were not executed.** This Mac has no container runtime (no Docker
   daemon, Podman or Colima). Linux evidence is limited to musl cross-compilation and
   linking (rows 10–12). The Static Linux SDK has no `Testing` module, so the test
   target can't be cross-built. `linux.yml` (Ubuntu 24.04, Swift 6.4.0 container,
   x86_64 + arm64) runs the full suite on glibc. Its result on the PR is the Linux
   test evidence and has to be checked there.
2. **CI not yet observed green.** `native.yml` targets the self-hosted `xcode-27`
   runner. Self-hosted runners on a personal account are registered per repository,
   so the runner may need to be added to `ThorFuchs/Swift-SQLite` before the job
   leaves the queue.
3. **iOS 18 runtime not installed.** The simulator run used the iOS 27.2 runtime with
   deployment target 18.0. A device or iOS 18 runtime run was not done, so the
   file-protection effect on a real data-protected volume is unverified; only the
   open-flag mapping is tested.
4. **Apple private framework name clash.** macOS ships
   `/System/Library/PrivateFrameworks/SQLiteSwift.framework`. Its Objective-C-visible
   class `SQLiteSwift.Connection` clashed with an internal class here (objc runtime
   warning in test processes). Fixed by giving all internal classes an `SQLite` prefix
   (`c425821`). Apple's current class names are `Connection`, `Statement`,
   `TableBuilder`, `DateFunctions` and two private coders. Future macOS releases could
   add more names, so the module name `SQLiteSwift` carries a small residual risk.
   The fallback would be renaming the module; the spec currently fixes the name.
5. **Durability against power loss** is configured (`synchronous=FULL`, optional
   `appleFullFSync`) but can't be proven by tests. The crash-image test covers
   process-crash consistency, not drive write caches.
6. **Persistent WAL on Apple.** Apple's SQLite keeps an empty `-wal` file after close;
   Linux deletes it. Tests accept either.
7. The pending-waiter queue for connections is bounded only by the number of calling
   tasks. There is no separate admission limit.
8. The repository `ThorFuchs/Swift-SQLite` (private) was already created and seeded
   with an "Initial commit" outside this session before the branch was pushed.
