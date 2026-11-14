# Model layer: architecture decisions and evidence (G0)

**Status:** accepted design for implementation, 14 November 2026. Nothing described
under "Decisions" exists as public API yet. This document is gate **G0** of the plan
in the model-layer architecture dossier (14 November 2026) and records the evidence
the later gates build on.

**North star:** value snapshots for truth; explicit conditional transactions for
persistence; bounded committed-change streams for observation; observable handles
only for local editing; no silent state, identity or commit guarantees.

Evidence grades used below:

- **[RUN]** executed for this document, with the command and result given.
- **[SPIKE]** behavior shown by the research tests of PR #9.
- **[DESIGN]** a decision or target; not implemented.

## 1. Baseline

| Item | Value |
| --- | --- |
| `main` | `18074b3e3bf733188ba8091393484d2194d74662` |
| PR #9 head / base | `7e4cdbf8057cbbd8bd82a0090ed03bb362c8bd6a` / `741ca26da4eebae72b08386519bf9c3bebb3445b` |
| PR #11 head (lock fix) | `d7a688690d13cf95a86ee233e072715131d8c24a` |
| Host | macOS 27.3, Xcode 27.2, Apple Swift 6.4.2, system SQLite |
| Linux | CI container Swift 6.4.0, Ubuntu 24.04, pinned SQLite 3.54.1 |

[RUN] on the host above:

| Command | Ref | Result |
| --- | --- | --- |
| `swift test` | `main` | 84 tests in 11 suites passed |
| `swift test --filter ObservableSpikeTests` | PR #9 | 13 tests passed |
| `swift test` | PR #9 | 97 tests in 12 suites passed |
| 25 repeated runs of the spike suite | PR #9 | 25 of 25 passed |
| `swift test --sanitize=thread` | PR #9 | spike suite clean |
| `swift test`, `--sanitize=thread`, `--sanitize=address` | PR #11 | 84 passed each; no reports |

CI: Linux x86_64 and arm64 pass on `main`. The Linux sanitizer job reported
ThreadSanitizer races depending on test order, all inside
`Synchronization.Mutex.withLock`, which ThreadSanitizer cannot see on Linux.
PR #11 replaces `Mutex` with a `pthread_mutex_t`-based lock; on PR #11 the Linux
sanitizer job (ThreadSanitizer and AddressSanitizer) passes. This is a core
release gate, independent of the model layer.

## 2. Core APIs the model layer builds on

The model layer uses only public `SQLiteSwift` API. G1 to G5 need **no change to
the core**:

| Need | Core API |
| --- | --- |
| Atomic batch with a domain outcome | `SQLiteDatabase.writeOrRollback(limits:_:)` |
| Revision check | `SQLiteTransaction.compareAndSet(table:idColumn:versionColumn:id:expectedVersion:assignments:alsoRequire:)`; it already refuses `expectedVersion == Int64.max` |
| Identity (incarnation) check | the `alsoRequire:` predicate of `compareAndSet` |
| Commit uncertainty | `SQLiteError.Code.commitOutcomeUnknown`, `writeReportingOutcome`, `resolveCommit(limits:_:)` |
| Bounded time and work | `SQLiteOperationLimits` |
| Exact bytes | `queryRaw` / `executeRaw` |
| Real unknown-commit tests | the internal `failNextCommitForTesting` hook, via `@testable import` |

`SQLiteTransaction` is non-`Sendable` and lives only inside its synchronous closure;
the model layer never lets it escape. `RETURNING` (SQLite 3.35+) is available on
every supported platform.

## 3. Decisions

### M1. Two targets, unreleased until G5

| Target | Contents | Depends on |
| --- | --- | --- |
| `SQLiteSwiftModels` | record descriptors and codecs, `RecordSnapshot`, `RecordVersion`, conditional insert/update/delete, atomic batches, the managed store with its committed-change stream and live queries | `SQLiteSwift` only |
| `SQLiteSwiftModelContext` | `@Observable` handles, context-local identity map, `save()`, conflict resolution | `SQLiteSwiftModels`, `Observation` |

The change stream lives in `SQLiteSwiftModels` because only the store sees every
managed write. Both targets stay without a product until G5 passes, so the API can
change without breaking SemVer; they ship as products in a 1.x minor release
(G6). The core keeps zero dependencies and no `Observation` import.

Rejected: three targets (observation split from models adds a boundary without a
separate dependency); one target with `Observation` (would force it on server-only
consumers).

### M2. Manual record descriptors first

A record is a plain `Sendable`, `Equatable` struct with an `ID`. A descriptor names
the table, the key column and, per field, the column and a codec. Codecs decide
SQL affinity, `NULL` handling, and the exact representation of dates and decimals;
`Codable` is not the mapping. Decoding distinguishes *no row*, *SQL NULL*, *invalid
stored value* and *schema mismatch*. SQL stays available as an escape hatch.

Macros come only after this API is stable, in a separate companion package (no
SwiftSyntax in this repository), checked against hand-written descriptors.

### M3. Identity: incarnation plus revision

Each managed table has, besides its key, two store-owned columns:

- `revision INTEGER NOT NULL CHECK (revision >= 1)`, incremented by every update;
- `incarnation BLOB NOT NULL`, 16 random bytes (`randomblob(16)`) set on insert and
  never changed.

`RecordVersion` is the pair. Updates and deletes check both: the revision through
`compareAndSet`, the incarnation through `alsoRequire`. A row that was deleted and
re-created under the same key has a new incarnation, so a stale handle gets a
conflict instead of overwriting it (no ABA). Keys may be reused deliberately; a
reused key is a new record.

Rejected: the permanent identity registry of PR #9 (grows without bound, needs a
trigger, and privileged SQL can bypass it). Keys that must never be reused are a
domain rule; a consumer can still add such a registry itself.

### M4. Truthful write outcomes

Writes take an expectation (`absent`, or a `RecordVersion`) and return
`inserted`, `updated`, `deleted`, `conflict(current:)` or `missing`, each with the
snapshot it produced or found. Lock contention, deadlines, cancellation, constraint
errors and `commitOutcomeUnknown` stay `SQLiteError`s and are never folded into an
outcome. There is no upsert without an expectation and no
`ON CONFLICT DO UPDATE` behind the caller's back. A batch is one
`writeOrRollback`: the first conflict rolls back the whole batch and names the
record that conflicted.

### M5. Editing context

`SQLiteModelContext` is `@MainActor`, context-local, and never global. It maps
`(record type, ID)` to one handle and re-checks after every suspension, so concurrent
`find`s return the same handle. Handles are held weakly or released with
`forget(_:)`. Server code uses the store's value API, not a context.

A handle keeps the working value, the baseline snapshot, an optional remote snapshot
and a state (`clean`, `dirty`, `saving`, `conflicted`, `deleted`, `indeterminate`).
The **edit generation counts only local edits**; applying a remote snapshot to a
clean handle does not touch it (fixes the coupling noted in PR #9 review).
Resolution is explicit: `useRemote()`, `keepLocal()` (re-base onto the latest known
remote version; the next save is still conditional) and `discard()` (the only way
out of a conflict with a deleted row). A remote deletion never becomes an insert.

Save captures every dirty handle's outgoing value, version and generation; marks them
`saving`; runs one batch; on commit advances baselines to the versions the database
returned (never `revision + 1` computed locally); keeps later edits dirty; on a
conflict or a known rollback restores editability without blaming unrelated
handles; on `commitOutcomeUnknown` marks the batch `indeterminate` and blocks further
saves until resolved.

### M6. Commit-outcome markers: as short-lived as possible

Every managed batch inserts one row into the store table
`sqliteswift_model_operations (id BLOB PRIMARY KEY, created_at INTEGER NOT NULL)` in
the same transaction. When the outcome is known, the store deletes the marker in its
next write. An unknown outcome is resolved with `resolveCommit` probing for that
marker. After a crash, unsaved edits are gone with the process and the next read
shows the truth, so restart recovery reduces to cleanup: on open, the store deletes
markers older than a configurable retention (default 7 days).

### M7. Committed-change stream

- **Scope:** writes made through the managed store in this process. Raw SQL writes,
  other `SQLiteDatabase` instances and other processes produce no events. This
  limitation is documented, not hidden.
- **Order:** every managed batch increments `sqliteswift_model_sequence.value` in the
  same transaction and reads it back with `RETURNING`. With one writer connection,
  the sequence is the commit order. Batches are published in sequence order, only
  after the write returned committed; a rolled-back batch publishes nothing and an
  unknown one publishes only after it was resolved as committed.
- **No lost first update:** a subscriber registers first, then reads its snapshot in
  a read transaction that also reads the sequence (the watermark). Events at or
  below the watermark are dropped; everything after it is delivered.
- **Bounded:** each subscriber has a fixed buffer. On overflow it receives
  `resyncRequired` and must read a new snapshot; nothing grows without limit.
- **Lifetime:** a subscription ends when its consumer task is cancelled or the
  store closes; no detached tasks.
- **Payload:** events carry record identities, kinds and versions, not row bodies.

Rejected for v1: `sqlite3_update_hook` (misses `WITHOUT ROWID` tables and
`DELETE` without `WHERE`, and still only sees this connection); cross-process change
detection (`PRAGMA data_version` polling may come later as a separate, explicitly
weaker opt-in).

### M8. Store-owned schema

The store's tables (`sqliteswift_model_operations`, `sqliteswift_model_sequence`)
are created by a migration the store provides and the consumer includes in its own
numbered migration list, so `user_version` stays the consumer's single schema
version. Managed tables declare `revision` and `incarnation` in the consumer's
migrations; the descriptor checks their presence at first use.

### M9. Raw SQL

Raw SQL stays fully supported. Writes that bypass the store bypass its guarantees:
no events, and no revision or incarnation maintenance unless the SQL does it. The
documentation says so plainly; no trigger enforces it in v1.

## 4. PR #9 evidence matrix

| Spike test | Shows | Status for the model layer |
| --- | --- | --- |
| `casAndRollback` | revision CAS across two databases; `writeOrRollback` discards a batch; a rolled-back insert retires no identity | tested; carried into G2 |
| `conditionalPutAndDelete` | insert-if-absent, update-if-revision, revision-checked delete, `retired` | tested at store level; G2 replaces `retired` with incarnation (M3) |
| `concurrentStores` | two writers, one wins, one conflicts | tested; G2 adds delete-vs-update and insert-vs-insert |
| `contextIdentitySaveAndRefresh` | one handle per ID, explicit save, manual refresh, dirty kept on refresh | tested; refresh becomes event-driven in G5 |
| `conflictRollsBackBatchAndCanResolve` | batch rollback, only the conflicting record conflicted, `keepLocal` | tested; carried into G3 |
| `editDuringAwaitedSaveAndOverlap` | edits during a suspended save survive; overlapping save refused | tested; carried into G3 |
| `cancelledSavePreservesEdits` | cancellation before database work | partial: G3 adds cancellation during lock wait, during the statement and around `COMMIT` |
| `unknownCommitResolution` | marker probe, simulated before and after commit | partial: G3 adds a real unknown commit via the internal hook and marker cleanup |
| `failedResolutionRemainsIndeterminate` | failed resolution keeps `indeterminate` | tested; carried into G3 |
| `unknownCommitThenRemoteWriteDoesNotOverwrite` | after resolution, a third party's write still conflicts | tested; carried into G3 |
| `remoteDeletionDoesNotResurrect` | remote deletion is a conflict, not an insert | tested; gap: no way out of the conflict, fixed by `discard()` (M5) |
| `nestedObservationAndGeneration` | nested struct writeback is observed; generation keeps later edits | tested; M5 separates edit generation from remote updates |
| `cleanRefreshAndDeletion` | clean handle adopts remote; deletion marks `deleted` | tested |

The dossier also mentions an earlier five-test spike; its source is not in this
repository, so it is not compared here.

## 5. Gate plan

| Gate | Deliverable | Acceptance (executed, not reviewed) | Status |
| --- | --- | --- | --- |
| G0 | this document | baseline runs in section 1 | done |
| G1 | `SQLiteSwiftModels`: record protocol, descriptors, codecs, snapshots, versions | three record types with different keys, nullable and BLOB fields round-trip; negative codec and schema tests | design |
| G2 | conditional insert/update/delete, batches, outcomes (M3, M4) | two writers; delete vs update; insert vs insert; key reuse gets a new incarnation; `Int64.max`; whole-batch rollback | design |
| G3 | `SQLiteSwiftModelContext` (M5, M6) | every state transition with barriers, no sleeps; cancellation in each phase; a real unknown commit; no lost edit | design |
| G4 | committed-change stream (M7) | no event on rollback or unresolved unknown; watermark handoff under concurrent subscribe; overflow → `resyncRequired`; cleanup on cancel and close | design |
| G5 | `observe(record:)`, table-scoped live queries | two contexts: clean handles update, dirty ones keep their draft, remote deletion is shown | design |
| G6 | products, DocC, changelog, developer-kit recipes, 1.x release | macOS, iOS cross-compile, Linux, ThreadSanitizer and AddressSanitizer, API check | design |
| G7 | optional: macro companion package; Hummingbird/SSE demo | outside this package | design |

Each gate is one pull request. Each report lists the ref and files, the commands run
with test counts and platforms, a behavior matrix (commit, conflict, missing, delete,
ABA, indeterminate, cancellation, reentrancy, subscription, cross-process), API
consequences, risks, and the next small step.

**Stop conditions:** a genuine data race, an unreconciled commit ambiguity, a lost
local edit, a lost first subscription update, a queue that cannot be bounded, or a
required source break in the frozen core API stops the work and is reported.

## 6. Open points for later gates

- Exact codec set for G1 (dates, decimals, UUIDs) and naming review against
  Swift Package Index conventions.
- Whether `SQLiteModelContext` later needs a non-main-actor variant; not before a
  concrete consumer needs it.
- Durable outbox or replay for events across restarts: out of scope for v1;
  subscribers re-snapshot.
- Cross-process observation: out of scope for v1 (M7).
