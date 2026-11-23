# Versions and products

The kit is validated against library **1.2.0** (tag `1.2.0`). Use only APIs that
exist in the version the consumer actually resolves.

| Library version | Adds |
| --- | --- |
| 0.1.0 | `SQLiteDatabase` (one writer, reader pool, own threads), `SQLiteConfiguration`, migrations on `user_version`, `write`/`read`/`writeOrRollback`, `execute`/`query`/`queryOne`/`scalar`, `compareAndSet` with `alsoRequire`, `queryPage` keyset paging, `readBlob`, `deleteExpired`, limits, `SQLiteSwiftTesting` with the conformance kit |
| 0.2.0 | `writeReportingOutcome`, `resolveCommit`, `commitOutcomeUnknown`; `SQLiteOperationLimits` (deadlines, instruction budgets); `queryRaw`/`executeRaw` with `SQLiteRawValue`; `SQLiteFileIdentity`; extended settings and `effectiveSettings()`; `SQLiteError` and conformance checks become extensible structs |
| 0.9.0 | API freeze for 1.0.0. `SQLitePredicate` is a struct (build with the same `.equals`, `.notIn`, … spellings; don't pattern-match on cases); `SQLiteError.isStop` renamed `isInterruption`; `SQLiteSynchronous.extra`; new codes `schemaMismatch`, `invalidStoredValue`; new products `SQLiteSwiftModels` and `SQLiteSwiftModelContext` |
| 1.0.0 | The first stable release: the 0.9.0 API, unchanged. Upgrading from 0.9.0 needs only the new requirement |
| 1.1.0 | `backup(to:)`, `vacuum(into:)`, `integrityCheck()`, `quickCheck()`, `optimize()`, `incrementalVacuum(pages:)`; `SQLiteObserver`, `SQLiteObservers`, `SQLiteConfiguration.observer`; `verifiesMigrationChecksums` and code `migrationModified`; FTS5 on Linux; `SQLiteSwiftTesting.injectFault(_:)`; product `SQLiteSwiftServer` with traits `Metrics`, `Tracing`, `Logging`, `ServiceLifecycle` |
| 1.2.0 | `SQLiteModelStore.records(_:where:limits:bufferSize:)` (`SQLiteLiveRecords`); `SQLiteModelStore(database:changeLog:)`, `ChangeLog.retain(batches:)`, `subscribe(after:bufferSize:limits:)`, `SQLiteModelSchema.changeLogMigration(version:)`; `fetchAll(_:sql:_:limits:)` |

From 1.0.0 on, minor releases only add API, error codes and conformance checks;
only a major release may break source compatibility, so `from: "1.0.0"` is safe.
A consumer still on 0.x pinned with `.upToNextMinor(from:)`; moving from 0.9.0 to
1.0.0 needs no code change, from 0.2.0 see the 0.9.0 breaking changes above.

## Manifest

```text
.package(url: "https://github.com/ThorFuchs/Swift-SQLite.git", from: "1.2.0")

.product(name: "SQLiteSwift", package: "Swift-SQLite")             // library code
.product(name: "SQLiteSwiftModels", package: "Swift-SQLite")       // records, store
.product(name: "SQLiteSwiftModelContext", package: "Swift-SQLite") // app editing context
.product(name: "SQLiteSwiftTesting", package: "Swift-SQLite")      // test targets only
```

Platforms: macOS 15+, iOS 18+, Linux (x86_64, arm64). Toolchain: Swift 6.4,
language mode 6. Apple platforms link the system SQLite; Linux compiles a pinned
amalgamation. There are no other dependencies.
