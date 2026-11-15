# Swift-SQLite roadmap

Status: updated 15 November 2026. **1.0.0 is released** (stable API, model layer,
public polish). Next: **1.1.0** makes the
package operable on a server (backups, maintenance, instrumentation, fault
injection), **1.2.0** brings the model layer to servers (async live queries, a
resumable change stream), and the opt-in profiles follow by consumer demand.
Original proposal: 12 November 2026. It extends the 0.1.0 scope (ADR-0004 phase C
requirements from MCP-Server) with what we learned from the Content Collections
compatibility brief of 12 November 2026. Versions are targets, not commitments.
Nothing here changes 0.1.0 defaults.

## Guiding rules

- **Opt-in profiles, stable defaults.** New behavior arrives as named profiles or
  options. An existing database or configuration never changes behavior because a
  newer version of the package added capabilities.
- **Verify, don't assume.** Every setting a profile depends on is read back after it
  is applied. A mismatch fails closed with a typed error; there is never a silent
  fallback.
- **Truthful outcomes.** The API reports only what it actually knows. "Unknown" is a
  valid, typed answer.
- **Generic primitives here, policy in consumers.** Swift-SQLite owns engine,
  connections, workers, transactions, verification and bounded reads. Consumers own
  schemas, journals, CAS tokens, leases, pins, retention and recovery policy.

## Consumers and what they need

| Consumer | Uses Swift-SQLite for | Needs most from the roadmap |
| --- | --- | --- |
| Swift-MCP-Server-Core (MCP Tasks, ADR-0004 C/D) | Durable task store, CAS transitions, exactly-once inputs | Truthful commit outcomes, operation budgets and deadlines, settings verification |
| Swift-Content-Collections (RC1, S09/S11/S15) | Generation store (rollback, `EXTRA`), read-only SQLite source | Rollback store profile, read-only source and image profiles, confinement, raw byte-exact rows, an isolated engine |
| Swift-JSON (later versioned envelope) | Canonical JSON bytes as BLOBs | Raw byte-exact rows, bounded BLOB reads, file identity (`application_id`) |
| Apps on iOS 18+ | Local persistence | Same behavior on every OS version, file protection, rollback mode where WAL sidecars are a problem |
| Server applications (Hummingbird, Vapor, MCP servers) on Linux | Persistence, queries, change feeds | Backups and maintenance, metrics and tracing, graceful shutdown, an async change feed for SSE and WebSockets |

## What we take from the Content brief

| Brief item | Decision | Why |
| --- | --- | --- |
| Three-way commit outcome (B3) | **Adopt for all consumers; 0.1.0 has the typed `commitOutcomeUnknown`** | MCP's exactly-once inputs have the same problem. A thrown `COMMIT` error does not prove non-commit |
| Settings readback, fail closed (B1) | **Adopt generally** | Also protects the WAL profile, for example against a filesystem that refuses WAL |
| Rollback-journal durable profile (`DELETE`, `EXTRA`, `fullfsync`) (B1) | **Adopt as an opt-in profile** | Single-writer stores, network-shy app containers, consumers that want no sidecar files |
| File identity on creation, fail closed on existing files (`page_size`, encoding, `auto_vacuum`, `application_id`, `user_version`) (B1) | **Adopt as a generic `SQLiteFileIdentity`** | Stops a consumer from opening the wrong file. The values are the consumer's (Content's `0x53434339` and `user_version 1` stay Content's) |
| Operation budget via progress handler, first-cause latching (C4) | **Adopt generally** | Bounded CPU per operation for every consumer; complements `sqlite3_interrupt` |
| Per-operation deadline (B2) | **Adopt generally** | Bounded wall time without the caller building timers around tasks |
| Raw, byte-exact rows (C4) | **Adopt generally** | Today TEXT decodes into Swift `String`, which repairs invalid UTF-8. Canonical-bytes consumers need exact bytes, including embedded NUL |
| Read-only source profile (`READONLY \| NOFOLLOW \| PRIVATECACHE`, no writer, no pragmas that write) (C2) | **Adopt** | Reading foreign or published databases safely is a general need |
| Immutable image via `sqlite3_deserialize(READONLY)` with explicit buffer ownership (C1) | **Adopt** | Safe inspection of untrusted or packaged databases without touching the filesystem |
| Confinement: deny-by-default authorizer through reprepare, `SQLITE_PREPARE_NO_VTAB`, defensive, `temp_store=MEMORY`, `sqlite3_limit` table (C3) | **Adopt as a `SQLiteConfinement` option** | Needed whenever SQL or database content is not fully trusted |
| Isolated, prefixed, source-identified engine on all platforms (A1–A4) | **Adopt behind a probe** (later) | Apple's system SQLite differs by OS version (iOS 18 ships an older SQLite than macOS 27) and is compiled with options that conflict with strict profiles (`DQS=3`, `THREADSAFE=2`, mmap up to 1 GiB, shared cache, `USE_URI`). One engine everywhere gives every consumer reproducible behavior |
| Source generation from Fossil sources with Tcl (A2) | **Adopt as an optional provenance mode** | Release amalgamation plus published hash stays the default; generation from a pinned check-in is offered when a consumer requires it |
| Lock-file primitive and documented VFS assumptions (B4) | **Adopt the primitive and documentation** | Companion locks are a recurring need; POSIX `fcntl` lock semantics are a common trap |
| Activity registry, generation pins, retention, GC, request journal, seal rules | **Not adopted** | Domain policy; stays in Content (and in MCP for its equivalents) |
| Content's private `CSQLite` target ownership | **Respected** | Swift-SQLite offers the engine as a vendorable closure *and* as an optional product; consumers choose |

## Path to 1.0.0

1.0.0 is a promise: no source-breaking change before 2.0.0. Everything that could
force a break lands first.

| Version | Content | Status |
| --- | --- | --- |
| 0.1.0 | Base package, MCP-Server prerequisites | released (tag `0.1.0`) |
| 0.2.0 | Commit outcomes, operation limits, raw rows, file identity, extended settings; `SQLiteError` and `SQLiteConformanceKit.Check` become extensible structs | released (tag `0.2.0`) |
| 0.9.0 | API review and freeze; community files (SECURITY, CONTRIBUTING, code of conduct, issue and PR templates); CI gates (Thread and Address Sanitizer, API-breakage check against the last tag, release build, Dependabot for actions); hosted DocC; Swift Package Index (`.spi.yml`); public README; SemVer policy; branch protection (enabled 2026-11-15); macOS CI for fork PRs on GitHub-hosted runners if available | released (tag `0.9.0`, release candidate) |
| 0.9.0 (model layer) | Opt-in model layer (`SQLiteSwiftModels`, `SQLiteSwiftModelContext`) joins the release candidate and its API freeze: record snapshots, conditional writes, a committed-change stream and observable editing handles. Decisions and gates: [MODEL-ARCHITECTURE.md](Documentation/MODEL-ARCHITECTURE.md) | released in `0.9.0` |
| 1.0.0 | Tagged with a GitHub Release once 0.9.0 has been validated by MCP-Server-Core without API changes | released (tag `1.0.0`); Core validated 0.9.0 green with only its pin changed |
| 1.1.0 | Operate it on a server: online backup, `VACUUM INTO`, integrity checks, explicit maintenance, dependency-free instrumentation hooks, public fault injection, migration checksums, FTS5 on Linux | planned |
| 1.2.0 | The model layer on the server: an async live query without the main actor, a resumable change stream, `Observations` support, records from custom SQL, an opt-in Swift-JSON codec | planned |
| 1.3.0+ | Opt-in profiles (rollback store, read-only source and image, confinement, lock file), scheduled when a consumer needs them | by demand |
| Later | One isolated engine everywhere, gated by a probe; the modern-Swift watch list | probe first |

## Phases

### 0.1.0: acceptance candidate (PR #1) — downstream requirements done

Done after the MCP-Server downstream review (ADR-0004 phase C prerequisites):

| Change | Status |
| --- | --- |
| Truthful commit errors: `SQLiteError.commitOutcomeUnknown(_)` when `COMMIT` failed and the transaction ended; every other thrown error means "not committed" | done |
| `fullfsync` + `checkpoint_fullfsync` on by default on Apple platforms (opt-out `appleFullFSync = false`) | done |
| Read-back verification of every applied pragma (`.settingMismatch`), `effectiveSettings()` | done (subset of 0.2.0 item 2) |
| Guarded compare-and-set with typed `SQLitePredicate` and `.guardFailed(currentVersion:)` | done |
| Keyset pagination (`queryPage`) | done |
| Typed `.cantOpen` and `.ioError` (extended code); non-writable file fails at open with `.readOnly` | done |
| `close()` contract: running work finishes, waiting work gets `.closed`, threads joined before return | done (tested) |

### 0.2.0: truthful and bounded (all consumers) — done

Delivered as planned, with these refinements: the budget is named
`maxInstructions` and reported as `.instructionLimitExceeded`; the deadline is a
`timeout` that also bounds the wait for a connection; the file identity leaves
`user_version` to migrations and offers `adoptsUnmarkedFiles`; raw values can also
be bound (`executeRaw`). The originally planned items:

1. **Commit outcomes.** `SQLiteCommitOutcome<Value>` (`.committed`, `.notCommitted`,
   `.unknown`) with `writeReportingOutcome(_:)`. A documented resolution pattern: the
   consumer writes an idempotency key in the same transaction and resolves `unknown`
   with a fresh read after the original operation has stopped. A helper
   `resolveCommit(probe:)` runs that read on a fresh connection.
2. **Settings verification, extended.** 0.1.0 already reads back every pragma it
   sets (`.settingMismatch`) and reports `effectiveSettings()`. 0.2.0 adds
   `mmap_size`, limits and `PRAGMA compile_options` to the report, and applies the
   same checks to the new profiles.
3. **Operation budgets and deadlines.** `SQLiteOperationLimits` on each
   `read`/`write`: `maxVirtualMachineSteps` (progress handler every 1,000
   instructions) and `deadline`. The first cause is latched and reported as a typed
   `.budgetExceeded(.steps | .deadline | .cancelled)`. The handler is bound to the job
   token, so it can never fire for a later borrower of the connection.
4. **Raw rows.** `SQLiteRawValue` (`.null`, `.integer(Int64)`, `.real(Double)`,
   `.text(bytes: [UInt8])`, `.blob([UInt8])`) and `queryRaw(_:)`. Byte budgets count
   raw lengths. The existing `SQLiteValue` API stays.
5. **File identity.** `SQLiteFileIdentity` (`applicationID`, `pageSize`,
   `autoVacuum`, optional fixed `userVersion`): applied in one transaction when the
   file is new, checked and never rewritten otherwise.
6. **Late-interrupt proof.** A test that an interrupt or progress stop issued at the
   end of one job never affects the next job on the same connection.

Acceptance: conformance-kit checks `commitOutcome`, `settingsVerification`,
`operationBudget` and `fileIdentity`, under every existing configuration.

### 1.0.0: finish the release

- Done: MCP-Server-Core builds and passes its task-store tests and the conformance
  kit on 0.9.0, also under ThreadSanitizer, with only its version pin changed.
- Re-pin the developer kit to 1.0.0 and run its recipes against the tag.
- List the package on the Swift Package Index (hosted DocC, badges).
- Done: build and test with the Swift 6.2 upcoming feature
  `NonisolatedNonsendingByDefault` (SE-0461); all tests pass, and CI keeps checking it.
- Done: a first benchmark baseline ([Documentation/Benchmarks.md](Documentation/Benchmarks.md)).

### 1.1.0: operate it on a server

The core is complete for storing data; this release makes it operable.

1. **Backups.** `database.backup(to:)` over `sqlite3_backup`, in steps, with progress,
   cancellation and an operation deadline; `VACUUM INTO` for a compact snapshot.
2. **Integrity.** `integrityCheck()` and `quickCheck()` with a typed result instead of
   text rows.
3. **Explicit maintenance.** Checkpoints on request, `PRAGMA optimize`, incremental
   vacuum. All called by the consumer; the package starts no background work.
4. **Instrumentation without dependencies.** Hooks in the core for statement time,
   the wait for a connection and for locks, checkpoints and limit stops. Bridges to
   swift-log, swift-metrics, swift-distributed-tracing and swift-service-lifecycle
   (`Service` with graceful `close()`) come as package traits (SE-0450) or a small
   companion package, so the core keeps zero dependencies.
5. **Fault injection for consumers.** The tests here inject unknown commits, busy
   locks and a full disk through internal hooks. `SQLiteSwiftTesting` makes them
   public, so consumers can test their own handling of these outcomes.
6. **Migration checksums.** A store table records each applied migration's hash; an
   edited shipped migration fails at open with a typed error instead of being a rule
   in the documentation.
7. **FTS5 on Linux.** Compile the vendored engine with FTS5, matching Apple's system
   SQLite, so full-text search works the same everywhere.
8. **Engine updates.** A scheduled workflow reports new SQLite releases; engine
   security fixes ship in patch releases.

Acceptance: each feature has tests on macOS and Linux, including cancellation and
deadline paths; backups are verified by opening and checking the copy.

### 1.2.0: the model layer on the server

1. **Async live query.** `store.records(_:where:)` as an `AsyncSequence` of snapshots,
   without the main actor, coalescing bursts of changes. It feeds SSE and
   WebSocket endpoints directly.
2. **Resumable change stream.** The store's sequence is already durable. A bounded
   change log lets a consumer call `subscribe(after: sequence)` after a restart
   (a transactional outbox), with `resyncRequired` when the log no longer reaches
   back far enough.
3. **`Observations`.** Document and test model handles and live queries with
   `Observations` (SE-0475, Swift 6.2, also on Linux) for consumers outside SwiftUI.
4. **Records from custom SQL.** `fetchAll(_:sql:_:)` maps a query's columns to a
   record by name, for joins and projections. No query builder.
5. **Swift-JSON codec.** Exact JSON values as a record column, behind an opt-in trait.

Acceptance: the G4 and G5 evidence standards (barriers, no sleeps, ThreadSanitizer)
apply, plus a restart test for the resumable stream.

### Modern-Swift watch list

Adopt when stable and useful, not before:

- `~Escapable` types (SE-0446): make "a transaction never leaves its closure" a
  compile-time guarantee.
- `Span` and `RawSpan` (Swift 6.2): read BLOBs without copying.
- Exit tests in Swift Testing: real crash-and-recover tests for the conformance kit.
- A macro companion package for record descriptors, once the hand-written API has
  proven itself in use.

### 1.3.0+ (was 0.3.0, then 1.1.0): profiles for durable single-writer stores and safe reading

Scheduled when a consumer (first Content-Collections) needs them.

1. **Rollback store profile.** `SQLiteConfiguration.rollbackStore(path:)`:
   - single connection, `journal_mode=DELETE`, `synchronous=EXTRA`,
     `locking_mode=NORMAL`, `foreign_keys=ON`, `trusted_schema=OFF`,
     `read_uncommitted=OFF`, `mmap_size=0`;
   - `fullfsync` requested and read back on Apple platforms;
   - finite busy handling;
   - every setting verified (0.2.0 item 2), with no fallback to WAL.

   Migrations are optional, so consumers with a fixed `user_version` can manage their
   schema themselves.
2. **Read-only source profile.** `SQLiteSource.open(path:)`:
   - a fresh `READONLY | NOFOLLOW | PRIVATECACHE` connection, no URI, no create;
   - no writer, no journal-mode change, no checkpoint;
   - one read transaction held until the last statement finishes and is finalized;
   - fails if the WAL sidecars it would need cannot be used.
3. **Image profile.** `SQLiteImage.open(bytes:)`:
   - `sqlite3_deserialize` with `SQLITE_DESERIALIZE_READONLY` on a fresh private
     connection;
   - header bytes 18/19 must be rollback mode;
   - the buffer is owned by the image until `close()` and returned on every error
     path.
4. **Confinement.** `SQLiteConfinement`:
   - a deny-by-default authorizer installed for the connection's lifetime (it
     survives automatic reprepare);
   - `SQLITE_PREPARE_NO_VTAB`, `SQLITE_DBCONFIG_DEFENSIVE`, `query_only`,
     `trusted_schema=OFF`, `temp_store=MEMORY`;
   - a finite `sqlite3_limit` table, exact tail checks and length-aware bindings.

   Usable with the source and image profiles and, optionally, with the default
   profile's readers.
5. **Locks and VFS.** `SQLiteLockFile`: `flock`-based, shared and exclusive,
   non-blocking with a deadline, on a separate file. Plus `Documentation/VFS.md`
   covering the unix VFS, POSIX advisory locks, local filesystems only, `fsync` vs
   `F_FULLFSYNC`, and why companion locks must never use the database file.

Acceptance: positive and negative tests for every setting and every failure path,
buffer lifetime, authorizer denial after reprepare, and a commit-fault/reopen probe in
rollback mode.

### Later (was 0.4.0, then 1.2.0): one isolated engine everywhere (gated by a probe)

**Probe first**, on a branch:

- a prefixed engine closure (every exported symbol renamed; `nm` inventory shows no
  unprefixed `sqlite3*` definitions);
- a coexistence executable linking the prefixed engine, system `libsqlite3` and
  `SQLiteSwift` in one process;
- macOS arm64 and Linux x86_64/arm64, debug and release;
- runtime readback of `sqlite3_sourceid`, version and compile options.

**Then, if the probe holds:**

1. **Engine selection** as a SwiftPM package trait, for example `IsolatedEngine`
   (default off). With it, Apple platforms also use the vendored engine. The compile
   options are those of the strict profile:
   - `THREADSAFE=1`, `DQS=0`, `OMIT_LOAD_EXTENSION`, `OMIT_SHARED_CACHE`;
   - `ENABLE_API_ARMOR`, `DEFAULT_FOREIGN_KEYS=1`, `DEFAULT_MEMSTATUS=0`,
     `MAX_MMAP_SIZE=0`.

   The Swift layer stays the same; only the C module behind it changes.
2. **Vendorable engine closure.** The same files, hashes, symbol inventory and
   verification script, packaged so a consumer can copy them into its own private C
   target (Content's `CSQLite`) without depending on this package.
3. **Provenance modes:**
   - the release amalgamation with the published SHA3-256 (default);
   - or generation from a pinned Fossil check-in (manifest hash, Git mirror commit,
     Tcl version, inputs and output hashes), done by an offline script and never
     during a build.

Acceptance: symbol-inventory test, coexistence test, compile-option readback per
tuple, and the full suite under the `IsolatedEngine` trait on macOS, iOS simulator
and Linux.

## Open questions

1. **Resolved:** 0.1.0 shipped with the typed `commitOutcomeUnknown`.
2. **Engine version** for the isolated engine: SQLite 3.54.1 (current release), or
   Content's 3.55.0 pre-release candidate `43a48f77…` once released?
3. **Package traits:** confirm they work with this repo's CI (Swift 6.4, Xcode 27.2)
   and with consumers that pin exact versions. Settled by the first trait in 1.1.0
   (instrumentation bridges); the engine probe reuses the answer.
4. **Packaging for Content:** vendored closure (no graph change) or a product
   dependency (needs Content's decision). Both are offered.
5. **Resolved (1.1.0): package traits in this repository.** Tested with Swift 6.4: a
   dependency used only by a disabled trait is neither resolved nor fetched, so the
   default graph stays empty, also for consumers of the `SQLiteSwiftServer` product.
6. **Change-log retention** for the resumable stream: by count, by age, or both, and
   who prunes it.

## Not planned

- Domain logic: task stores, leases, generation pins, retention, GC, request journals.
- Network filesystems, custom VFSs, encryption codecs.
- Loadable extensions, shared cache, memory-mapped I/O in strict profiles.
- A required dependency on Swift-JSON (the 1.2.0 codec is an opt-in trait).
- An ORM or query builder, `await` inside transactions, multiple writers,
  automatic retries of writes, and cloud sync.
- Change detection across processes by default; at most later, as an explicitly
  weaker opt-in based on `PRAGMA data_version`.
