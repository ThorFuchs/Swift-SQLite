# Swift-SQLite

[![Native CI](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/native.yml/badge.svg)](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/native.yml)
[![Linux CI](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/linux.yml/badge.svg)](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/linux.yml)
[![Release](https://img.shields.io/github/v/release/ThorFuchs/Swift-SQLite?include_prereleases&sort=semver)](https://github.com/ThorFuchs/Swift-SQLite/releases)
[![Swift 6.4](https://img.shields.io/badge/Swift-6.4-F05138.svg)](https://www.swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2015%2B%20%7C%20iOS%2018%2B%20%7C%20Linux-lightgrey.svg)](#installation)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Durable, bounded SQLite for Swift concurrency. Zero dependencies by default.

Swift-SQLite is a small foundation for building persistent stores on SQLite. It
gives you one writer and a pool of snapshot readers, each on its own thread; durable
commits that report their outcome truthfully; and a bound on everything: time, work,
rows and bytes. Your store keeps its domain logic, and this package handles
connections, transactions, migrations and the hard edges.

- **Core** (`SQLiteSwift`): connections, transactions, migrations, limits,
  compare-and-set, paging and truthful commit outcomes.
- **Opt-in model layer** (`SQLiteSwiftModels`, `SQLiteSwiftModelContext`): typed
  records, conflict-safe writes, a committed-change stream and an observable editing
  context for apps.
- **Conformance kit** (`SQLiteSwiftTesting`): 13 checks your own store runs in its
  tests.
- **Developer kit** for coding agents: a `swift-sqlite` skill with compiled recipes.

> **Status:** 1.0.0 is stable. From here on, only a major release may break source
> compatibility.

```swift
import SQLiteSwift

let database = try await SQLiteDatabase.open(
    SQLiteConfiguration(path: path),
    migrations: [
        SQLiteMigration(version: 1, name: "items", sql: """
            CREATE TABLE items (id TEXT PRIMARY KEY, version INTEGER NOT NULL DEFAULT 1, body BLOB NOT NULL);
            """)
    ])

try await database.write { tx throws(SQLiteError) in
    try tx.execute("INSERT INTO items (id, body) VALUES (?, ?)", ["a", .blob(bytes)])
}

let result = try await database.write { tx throws(SQLiteError) in
    try tx.compareAndSet(table: "items", id: "a", expectedVersion: 1,
                         assignments: [SQLiteAssignment("body", .blob(newBytes))])
}  // .updated, .conflict, .guardFailed or .notFound

let body = try await database.read(limits: SQLiteOperationLimits(timeout: .seconds(1))) { tx throws(SQLiteError) in
    try tx.readBlob(table: "items", column: "body", keyColumn: "id", key: "a")
}

await database.close()
```

## When it fits

Use Swift-SQLite when you build a store whose correctness you need to argue: a task
queue, a cache, a document or content store, a server component. It gives you
explicit transactions, SQL you write yourself, bounded resources, and no
automatic retries of your writes.

Look elsewhere if you want an ORM with query builders and associations, automatic
schema generation, or iCloud sync; GRDB, SQLite.swift, SwiftData and Core Data cover
those. Swift-SQLite's module is `SQLiteSwift`; it is unrelated to SQLite.swift
(module `SQLite`).

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.2.0"),
],
targets: [
    .target(name: "MyStore", dependencies: [
        .product(name: "SQLiteSwift", package: "Swift-SQLite"),
    ]),
    .testTarget(name: "MyStoreTests", dependencies: [
        "MyStore",
        .product(name: "SQLiteSwiftTesting", package: "Swift-SQLite"),
    ]),
]
```

| | |
| --- | --- |
| **Products** | `SQLiteSwift` (the library) and `SQLiteSwiftTesting` (conformance kit and test helpers); opt-in model layer: `SQLiteSwiftModels` and `SQLiteSwiftModelContext`; server bridges: `SQLiteSwiftServer`; Swift-JSON codecs: `SQLiteSwiftJSON` |
| **Platforms** | macOS 15+, iOS 18+, Linux (x86_64 and arm64) |
| **Toolchain** | Swift 6.4, Swift 6 language mode, strict concurrency, typed throws |
| **SQLite** | The system SQLite on Apple platforms; a pinned, unmodified SQLite 3.54.1 amalgamation on Linux ([provenance](Sources/CSQLiteSwift/PROVENANCE.md)) |
| **Dependencies** | None by default. The opt-in traits `Metrics`, `Tracing`, `Logging` and `ServiceLifecycle` add swift-metrics, swift-distributed-tracing, swift-log and swift-service-lifecycle, and `SwiftJSON` adds Swift-JSON; without them SwiftPM resolves nothing |

## What it guarantees

| Area | Behavior |
| --- | --- |
| Connections | One writer (`BEGIN IMMEDIATE`) plus a bounded reader pool (default 4) on WAL snapshot transactions. `readerCount = 0` selects a single connection. |
| Threads | Each connection runs SQLite calls on its own thread, never on the cooperative pool. `close()` lets running work finish, fails waiting work with `.closed` and joins the threads before it returns. No detached tasks, no global singletons. |
| Durability | Writes return only after `COMMIT`. `synchronous=FULL` by default (`NORMAL` and `EXTRA` as explicit options); on Apple platforms also `F_FULLFSYNC` by default. Every applied setting is read back at open; a mismatch throws `.settingMismatch`. `effectiveSettings()` reports what is in force. |
| Commit outcomes | A thrown error means "not committed", except `.commitOutcomeUnknown`: `COMMIT` was issued, failed, and the transaction ended. `resolveCommit` decides it with a fresh read on a new connection; `writeReportingOutcome` returns `.committed`, `.notCommitted` or `.unknown` as a value. |
| Time and work | Per-call or default deadlines and VM-instruction budgets (`SQLiteOperationLimits`), covering the wait for a connection and for locks. A stop rolls back and throws `.deadlineExceeded` or `.instructionLimitExceeded`; the first cause is reported, and a stop never reaches the next operation. |
| Busy and cancellation | A bounded busy timeout (default 5 s) ends in `.busy`. Task cancellation calls `sqlite3_interrupt`, rolls back and throws `.interrupted`. |
| Migrations | `PRAGMA user_version`, forward-only, one transaction per migration. A newer database is refused with `.schemaTooNew` and left untouched. |
| File identity | An optional `SQLiteFileIdentity` (`application_id`, `page_size`, `auto_vacuum`) is written to new files and checked on existing ones; the wrong file is refused with `.fileIdentityMismatch` and left untouched. |
| Bounded reads | Row limits and byte budgets on every query (1 MiB default, 16 MiB hard cap, also enforced as `SQLITE_LIMIT_LENGTH`), `length()` checks before loading BLOBs, and a bounded statement cache. Results are never silently truncated. |
| Byte-exact values | `queryRaw` and `executeRaw` keep TEXT as its stored bytes, including invalid UTF-8 and NUL. |
| JSON | SQLite's JSON functions on every platform, tested in CI: JSONB storage, path filters (`body ->> '$.status'`), `json_each` for arrays, indexes on paths, exact integers above 2^53. Typed predicates (`.equals("body", path: "$.status", "open")`, `.contains(…)`) render the same, index-friendly SQL. With the `SwiftJSON` trait, records store exact Swift-JSON values (`.jsonText`) and `Codable` types (`.json(T.self)`) as JSON text that those functions query. |
| Helpers | Compare-and-set with typed guards, keyset pagination, typed predicates with bound values, quoted identifiers, expiry queries on an injectable clock. |
| Observability | An optional `SQLiteObserver` sees every operation's kind, connection wait, duration and outcome, on the calling task. Bridges to swift-metrics, swift-distributed-tracing (spans nest under the request's span) and swift-log, plus a swift-service-lifecycle service, come as opt-in package traits. |
| Errors | `SQLiteError` carries a `code` that can grow without breaking your `switch`, plus typed detail. Catch by code: `catch SQLiteError.Code.busy`. |
| iOS | Optional data-protection class for the database files. |

## On a server

Turn on the traits you need. Without them the package still adds no dependencies:

```swift
.package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.2.0",
         traits: ["Metrics", "Tracing", "Logging", "ServiceLifecycle"]),
// target: .product(name: "SQLiteSwiftServer", package: "Swift-SQLite")
```

```swift
import SQLiteSwift
import SQLiteSwiftServer

var configuration = SQLiteConfiguration(path: path)
configuration.observer = SQLiteObservers(
    SQLiteMetricsObserver(database: "orders"),   // durations, waits, error counts
    SQLiteTracing.observer(),                    // a client span per operation
    SQLiteLoggingObserver())                     // failures and slow operations
let database = try await SQLiteDatabase.open(configuration, migrations: migrations)

let group = ServiceGroup(
    services: [httpServer, SQLiteDatabaseService(database, maintenance: .init(every: .seconds(300)))],
    gracefulShutdownSignals: [.sigterm], logger: logger)
try await group.run()   // closes the database on graceful shutdown
```

Backups (`backup(to:)`, `vacuum(into:)`), integrity checks and maintenance are
explicit calls; see Getting Started.

## Model layer (opt-in)

Two optional products build typed records on the core. They add no dependencies;
the core does not import them.

- **`SQLiteSwiftModels`** (servers and apps): records described with typed columns
  and strict codecs, immutable snapshots with a version (revision plus a random
  incarnation, so a reused key never matches an old version), writes that state
  what they expect (`insert`, `update(_:expecting:)`, `delete(_:id:expecting:)`)
  and return `inserted`, `updated`, `deleted`, `conflict(current:)` or `missing`,
  all-or-nothing batches, and `SQLiteModelStore` with a committed-change stream
  (snapshot handoff without gaps, bounded buffers, `resyncRequired`), resumable
  after a restart from an optional, bounded change log, and
  `store.records(_:where:)`, an `AsyncSequence` of live results for server push.
- **`SQLiteSwiftModelContext`** (apps): a main-actor `SQLiteModelContext` with one
  `@Observable` handle per record, atomic conditional `save()`, explicit conflict
  resolution, truthful handling of unknown commit outcomes, live handles and
  `SQLiteLiveQuery`.

```swift
let store = SQLiteModelStore(database: database)
let context = SQLiteModelContext(store: store)
if let article = try await context.find(Article.self, id: "intro") {
    article.value.title = "A better title"
    try await context.save()  // .saved, or .conflict if someone saved first
}
```

Design and evidence: [MODEL-ARCHITECTURE](Documentation/MODEL-ARCHITECTURE.md).
Guides: [Defining records](Sources/SQLiteSwiftModels/SQLiteSwiftModels.docc/DefiningRecords.md),
[Editing with a context](Sources/SQLiteSwiftModelContext/SQLiteSwiftModelContext.docc/EditingWithAContext.md).

## Documentation

- [Getting Started](Sources/SQLiteSwift/SQLiteSwift.docc/GettingStarted.md):
  migrations, reads and writes, compare-and-set, pagination, limits, commit
  outcomes and errors.
- API reference: every public symbol is documented in DocC. Build the archives
  for all three modules with `Scripts/build-docs.sh`.
- [CHANGELOG](CHANGELOG.md), including how to migrate between versions.
- [Developer kit](Documentation/AgentDeveloperKit.md) for coding agents (Claude Code,
  Codex): an instruction-only `swift-sqlite` skill with 20 compiled recipes. Install in
  Claude Code with `/plugin marketplace add ThorFuchs/Swift-SQLite`, then
  `/plugin install swift-sqlite@swift-sqlite`. Contributors: [AGENTS.md](AGENTS.md).
- [Roadmap](ROADMAP.md): after 1.0.0, operating it on a server (1.1.0: backups,
  maintenance, instrumentation, fault injection), the model layer on the server
  (1.2.0: async live queries, a resumable change stream), then opt-in profiles by
  demand.

## Test your store: the conformance kit

`SQLiteSwiftTesting.SQLiteConformanceKit` runs 13 checks against *your* migrations
and configuration: migrations, schema-too-new refusal, compare-and-set, commit
failures and outcomes, busy contention, cancellation, deadlines and budgets, WAL
checkpoints, recovery from a crash image taken mid-write, a full disk, the settings
in force, and the file identity.

```swift
import SQLiteSwiftTesting
import Testing

@Test(arguments: SQLiteConformanceKit.Check.allCases)
func conformance(check: SQLiteConformanceKit.Check) async {
    let result = await SQLiteConformanceKit(migrations: MyStore.migrations).run(check)
    #expect(result.outcome == .passed, "\(result.notes)")
}
```

## Versioning

Swift-SQLite follows [Semantic Versioning](https://semver.org). From 1.0.0 on:

- **Patch** releases fix bugs and update the vendored SQLite engine.
- **Minor** releases add API, error codes, conformance checks and opt-in options or
  profiles. Existing defaults and behavior don't change.
- **Major** releases are the only ones that may break source compatibility.

Error codes (`SQLiteError.Code`), predicates (`SQLitePredicate`) and conformance
checks (`SQLiteConformanceKit.Check`) are structs, so new ones never break a `switch`
that has a `default` branch. Enums whose documentation says "the cases are complete"
never gain cases. CI checks every pull request for API breakage against the latest
release.

Releases before 1.0.0 could break the API in a minor release; see the
[CHANGELOG](CHANGELOG.md) for upgrading from 0.x.

## Development

```sh
swift build
swift test
swift test --sanitize=thread
Scripts/build-docs.sh            # DocC; warnings are errors
Scripts/verify-amalgamation.sh   # the vendored SQLite is byte-identical to upstream
Scripts/check-api.sh             # API breakage against the latest tag
```

Cross-compile for iOS:

```sh
swift build --build-tests --scratch-path .build/ios --triple arm64-apple-ios18.0 \
  --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
```

Benchmarks (release build, separate package; baseline in
[Documentation/Benchmarks.md](Documentation/Benchmarks.md)):

```sh
Scripts/run-benchmarks.sh
```

Developer kit:

```sh
python3 Scripts/validate_developer_kit.py   # manifests, links, recipe markers, pins
Scripts/run_kit_recipes.sh                   # every recipe against this checkout
```

CI runs on macOS (build, tests, Thread Sanitizer, iOS cross-compile, docs, API check)
and on Linux x86_64 and arm64 (build and tests; Thread and Address Sanitizer on
x86_64), and validates the developer kit and runs its recipes. `main` is protected:
every pull request needs these checks to pass.

## Notes

- The module is named `SQLiteSwift`, not `SwiftSQLite`: macOS ships a private
  `SwiftSQLite.framework` that can be loaded into any process, and its
  Objective-C-visible classes would clash with a module of that name.
- Apple's system SQLite keeps the `-wal` file after the last connection closes
  (truncated to 0 bytes); Linux deletes it.

## Contributing and security

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[code of conduct](CODE_OF_CONDUCT.md). Please report vulnerabilities privately, as
described in [SECURITY.md](SECURITY.md).

## License

Swift-SQLite is licensed under the [Apache License 2.0](LICENSE); see also
[NOTICE](NOTICE). SQLite, compiled in on Linux, is in the public domain; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
