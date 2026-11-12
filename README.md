# Swift-SQLite

[![Native CI](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/native.yml/badge.svg)](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/native.yml)
[![Linux CI](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/linux.yml/badge.svg)](https://github.com/ThorFuchs/Swift-SQLite/actions/workflows/linux.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Durable, bounded SQLite for Swift concurrency. Zero dependencies.

Swift-SQLite is a small foundation for building persistent stores on SQLite. It
gives you one writer and a pool of snapshot readers, each on its own thread; durable
commits that report their outcome truthfully; and a bound on everything: time, work,
rows and bytes. Your store keeps its domain logic, and this package handles
connections, transactions, migrations and the hard edges.

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

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", .upToNextMinor(from: "0.9.0")),
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

From 1.0.0 on, use `from: "1.0.0"`.

| | |
| --- | --- |
| **Products** | `SQLiteSwift` (the library) and `SQLiteSwiftTesting` (conformance kit and test helpers) |
| **Platforms** | macOS 15+, iOS 18+, Linux (x86_64 and arm64) |
| **Toolchain** | Swift 6.4, Swift 6 language mode, strict concurrency, typed throws |
| **SQLite** | The system SQLite on Apple platforms; a pinned, unmodified SQLite 3.54.1 amalgamation on Linux ([provenance](Sources/CSQLiteSwift/PROVENANCE.md)) |
| **Dependencies** | None |

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
| Helpers | Compare-and-set with typed guards, keyset pagination, typed predicates with bound values, quoted identifiers, expiry queries on an injectable clock. |
| Errors | `SQLiteError` carries a `code` that can grow without breaking your `switch`, plus typed detail. Catch by code: `catch SQLiteError.Code.busy`. |
| iOS | Optional data-protection class for the database files. |

## Documentation

- [Getting Started](Sources/SQLiteSwift/SQLiteSwift.docc/GettingStarted.md):
  migrations, reads and writes, compare-and-set, pagination, limits, commit
  outcomes and errors.
- API reference: every public symbol is documented in DocC. Build it with
  `Scripts/build-docs.sh`.
- [CHANGELOG](CHANGELOG.md), including how to migrate between versions.
- [Roadmap](ROADMAP.md): the opt-in profiles planned after 1.0.0 (rollback store,
  read-only sources and images, confinement, one isolated engine on every platform).

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

Before 1.0.0, a minor release (0.x) may break the API; pin with
`.upToNextMinor(from:)`.

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

CI runs on macOS (build, tests, Thread Sanitizer, iOS cross-compile, docs, API check)
and on Linux x86_64 and arm64 (build and tests; Thread and Address Sanitizer on
x86_64).

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

Apache License 2.0; see [LICENSE](LICENSE). SQLite is in the public domain; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
