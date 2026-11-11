# Swift-SQLite 0.1.0 — acceptance report

Candidate for acceptance review, revised 2026-11-11 after the first review. Not
tagged, not released, not merged.

- **Source verified:** branch `swift-sqlite-0.1.0` at commit `b2082f2`
  (`b2082f22` …, "Rename module SwiftSQLite to SQLiteSwift"). The only later commit
  updates this file.
- **Modules:** `SQLiteSwift` (library), `SQLiteSwiftTesting` (test kit), `CSQLiteSwift`
  (Linux C target). The spec's names `SwiftSQLite` / `SwiftSQLiteTesting` were changed
  on review because they clash with a private Apple framework (see open point 4).
- **Spec:** `swift-sqlite-requirements.md` (MCP-Server session, ADR-0004 Tasks phase C)
  plus the task brief from the Swift-JSON session.
- **Machine:** macOS (Darwin 27.3, arm64). Swift 6.4.2 via swiftly
  (`TOOLCHAINS=org.swift.642202610261a`), Xcode 27.2 SDKs (macOS 27.2, iOS 27.2).
  System SQLite 3.54.0 on macOS/iOS; vendored 3.54.1 on Linux.

## Review changes (round 1)

| Request | Change | Evidence |
| --- | --- | --- |
| Linux glibc build failed: `pthread_setname_np` / `pthread_getname_np` not in scope | `65fa658`: `Sources/CSQLiteSwift/thread.c` + `include/csqliteswift_thread.h` wrap both calls. They are compiled in the Linux-only C target with `_GNU_SOURCE`; `WorkerThread.swift` calls them on Linux | Linux CI run 43079040926 on `65fa658`: x86_64 and arm64 both **45 tests passed**, including the thread-name test |
| Rename the module to avoid Apple's private `SwiftSQLite.framework` | `b2082f2`: `SwiftSQLite` → `SQLiteSwift`, `SwiftSQLiteTesting` → `SQLiteSwiftTesting`, `CSwiftSQLite` → `CSQLiteSwift`; thread names `sqliteswift.*`, probe tables `sqliteswift_probe*`, C helpers `csqliteswift_*`, DocC catalog `SQLiteSwift.docc`, README, CHANGELOG, workflows. Amalgamation bytes unchanged (verify script passes) | Clash check below; full local re-verification on a clean `.build` (commands table) |

**Clash check for `SQLiteSwift` (done before renaming):**

- No framework or module named `SQLiteSwift` exists in `/System/Library/Frameworks`,
  `/System/Library/PrivateFrameworks`, `/Library/Frameworks`, the macOS 27.2 and
  iOS 27.2 SDK framework directories, or the Swift 6.4.2 toolchain.
- A byte scan of the macOS dyld shared cache (`dyld_shared_cache_arm64e*`) finds no
  `SQLiteSwift` string. As a control, the same scan finds Apple's mangled
  `11SwiftSQLite` 14 times, so the method works.
- GitHub: no `Package.swift` declares a `SQLiteSwift` library. Repositories named
  `SQLiteSwift` are small, inactive Xcode projects (at most 6 stars, last pushed
  2016–2018) without `Package.swift`. SQLite.swift exports the module `SQLite`, and
  Vapor's package exports `SQLiteKit`; neither is affected.

## Summary

| Platform | What ran | Result |
| --- | --- | --- |
| macOS (arm64), local | `swift test`, 3 runs on a clean `.build` | **45 tests / 90 test cases in 6 suites passed**, exit 0 each run, 0 warnings |
| iOS simulator (iOS 27.2 runtime, iPhone 17 Pro, deployment target 18.0), local | `xcodebuild test` | **45 tests in 6 suites passed**, `TEST SUCCEEDED`, exit 0 |
| iOS device `arm64-apple-ios18.0`, local | cross-compile incl. tests | exit 0 |
| iOS simulator `arm64-apple-ios18.0-simulator`, local | cross-compile incl. tests | exit 0 |
| Linux glibc, Ubuntu 24.04, Swift 6.4.0 container, x86_64 + arm64 | GitHub Actions `linux.yml` | **45 tests in 6 suites passed on both architectures** (see "CI evidence") |
| macOS on the self-hosted `xcode-27` runner | GitHub Actions `native.yml` | passed (build, 45 tests, iOS cross-compiles, DocC); see "CI evidence" |
| Linux musl (Static Linux SDK 6.4.0, aarch64 + x86_64), local | cross-compile of both library products | exit 0 |
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
| Repository `Swift-SQLite`; library product/module and test kit; no module named `SQLite` | `Package.swift`: products `SQLiteSwift`, `SQLiteSwiftTesting`; C module `CSQLiteSwift`. The spec named these `SwiftSQLite` / `SwiftSQLiteTesting`; they were renamed on review because of Apple's private `SwiftSQLite.framework` (open point 4). The repository name is unchanged |
| macOS 15, iOS 18, Linux | `Package.swift` `platforms: [.macOS(.v15), .iOS(.v18)]`; iOS cross-compiles and simulator run; Linux CI on Ubuntu 24.04 (glibc, x86_64 + arm64) runs the full suite |
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
| Dedicated thread per connection, never the cooperative pool | `Internal/WorkerThread.swift` (one pthread per connection, FIFO jobs); `SQLiteConnection.run` bridges with a continuation. Test: *Closures run on dedicated named threads, not the cooperative pool* (thread names `sqliteswift.w` / `sqliteswift.rN`; passes on macOS, the iOS simulator and Linux glibc, where the names are set through the C wrappers in `Sources/CSQLiteSwift/thread.c`) |
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

Local environment for the `swift` commands (from the repository root):

```sh
set -a; . ~/.swiftly/env.sh; set +a
export TOOLCHAINS=org.swift.642202610261a SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
hash -r
```

Re-run after the rename on `b2082f2`, starting from `rm -rf .build`:

| # | Command | Exit | Outcome |
| --- | --- | --- | --- |
| 1 | `Scripts/verify-amalgamation.sh` | 0 | `Sources/CSQLiteSwift/sqlite3.c` and `include/sqlite3.h` SHA-256 match |
| 2 | `swift build --build-tests` | 0 | 0 warnings outside `sqlite3.c` |
| 3 | `swift build -c release --scratch-path .build/release-check` | 0 | |
| 4 | `swift test --xunit-output …` (runs 1, 2, 3) | 0, 0, 0 | 45 tests / 90 cases in 6 suites passed (0.97 s, 0.91 s, 0.93 s), 0 warnings |
| 5 | `SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) swift build --build-tests --scratch-path .build/ios --triple arm64-apple-ios18.0 --sdk "$SDKROOT"` | 0 | |
| 6 | `SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) swift build --build-tests --scratch-path .build/iossim --triple arm64-apple-ios18.0-simulator --sdk "$SDKROOT"` | 0 | |
| 7 | `Scripts/build-docs.sh` | 0 | DocC archive built with `--warnings-as-errors` |
| 8 | `swift build --scratch-path .build/linux --swift-sdk swift-6.4.0-RELEASE_static-linux-0.1.0 --triple aarch64-swift-linux-musl` (`SDKROOT` unset) | 0 | |
| 9 | Same with `--triple x86_64-swift-linux-musl` | 0 | |
| 10 | `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -scheme Swift-SQLite-Package -destination "id=<iPhone 17 Pro, iOS 27.2 simulator>" -derivedDataPath .build/xcode test` | 0 | `TEST SUCCEEDED`, 45 tests in 6 suites passed (4.2 s) |

Note on row 10: the first attempt ran in the shell with swiftly's `TOOLCHAINS`
override still exported. It failed to link (`posix_spawn failed`, exit 74) because
`xcodebuild` picked up the swiftly toolchain. Run `xcodebuild` with Xcode's own
toolchain, as in row 10.

## CI evidence (GitHub Actions on PR #1)

| Run | Commit | Job | Result |
| --- | --- | --- | --- |
| 43077752652 | `6b32330` | Linux / x86_64, Linux / arm64 | **failed**: glibc build error (`pthread_setname_np`), fixed in `65fa658` |
| 43077752962 | `6b32330` | macOS / build, test, iOS cross-compile, docs (`xcode-27`) | passed; Apple Swift 6.4.2; 45 tests in 6 suites passed |
| 43079040926 | `65fa658` | Linux / x86_64 | passed; Swift 6.4 (swift-6.4-RELEASE); **45 tests in 6 suites passed** |
| 43079040926 | `65fa658` | Linux / arm64 | passed; Swift 6.4 (swift-6.4-RELEASE); **45 tests in 6 suites passed** |
| 43079041048 | `65fa658` | macOS | cancelled (superseded by the push of `b2082f2`) |
| 43079739130 | `b2082f2` | Linux / x86_64 | passed; Swift 6.4 (swift-6.4-RELEASE); **45 tests in 6 suites passed** |
| 43079739130 | `b2082f2` | Linux / arm64 | passed; Swift 6.4 (swift-6.4-RELEASE); **45 tests in 6 suites passed** |
| 43079739107 | `b2082f2` | macOS (`xcode-27`) | queued for the self-hosted runner when this report was written; the same job passed on `6b32330`, and the change since then is the rename (verified locally, rows 1–10) |

## Not run, and open points

1. **Linux tests only in CI.** This Mac has no container runtime (no Docker daemon,
   Podman or Colima). Linux test evidence comes from `linux.yml` on GitHub Actions
   (table above). Locally, Linux was only cross-compiled against musl. The musl SDK
   exposed `pthread_setname_np` without `_GNU_SOURCE`, which is why the glibc failure
   was only seen in CI.
2. **Self-hosted macOS runner (maintainer action).** `native.yml` needs the
   self-hosted runner with label `xcode-27` registered for `ThorFuchs/Swift-SQLite`.
   The jobs above were picked up by such a runner, so it is reachable today. Keeping
   it registered for this repository is a maintainer task; this session did not
   change runner registration.
3. **iOS 18 runtime not installed.** The simulator run used the iOS 27.2 runtime with
   deployment target 18.0. A device or iOS 18 runtime run was not done, so the
   file-protection effect on a real data-protected volume is unverified; only the
   open-flag mapping is tested.
4. **Apple private framework name clash, resolved by renaming.** macOS ships
   `/System/Library/PrivateFrameworks/SwiftSQLite.framework`, which can be loaded into
   any process. Its Objective-C-visible classes (`SwiftSQLite.Connection`,
   `SwiftSQLite.Statement`, `SwiftSQLite.TableBuilder`, `SwiftSQLite.DateFunctions`
   and two private coders) share their names with classes of a module called
   `SwiftSQLite`. Under the old name, an objc runtime warning showed in test processes
   (`c425821`). The module is now `SQLiteSwift` (`b2082f2`), and internal classes
   keep their `SQLite` prefix as a second safeguard.
5. **Durability against power loss** is configured (`synchronous=FULL`, optional
   `appleFullFSync`) but can't be proven by tests. The crash-image test covers
   process-crash consistency, not drive write caches.
6. **Persistent WAL on Apple.** Apple's SQLite keeps an empty `-wal` file after close;
   Linux deletes it. Tests accept either.
7. The pending-waiter queue for connections is bounded only by the number of calling
   tasks. There is no separate admission limit.
8. The repository `ThorFuchs/Swift-SQLite` (private) was created and seeded with an
   "Initial commit" outside this session before the branch was pushed.
9. **Consumers** (MCP-Server-Core, Content-Collections, Swift-JSON) must use the new
   names: `.product(name: "SQLiteSwift", package: "Swift-SQLite")`,
   `import SQLiteSwift`, `import SQLiteSwiftTesting`.
