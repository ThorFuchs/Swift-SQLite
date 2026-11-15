# Verified public-API recipes

Use the relevant function in the [canonical executable source](../assets/consumer/Sources/Consumer/Consumer.swift).
Every Swift example in this kit is compiled and run as part of that consumer; there
are no separately maintained Markdown Swift snippets. The [manifest](../assets/consumer/Package.swift)
imports all four products for acceptance; a real target imports only what it uses.

| Marker / function | Since | Minimal imports | Behavior asserted |
| --- | --- | --- | --- |
| open-migrate / openAndMigrate | 0.1 | SQLiteSwift | Migration to `user_version` 1; older code refused with `schemaTooNew` |
| bound-values / boundValues | 0.1 | SQLiteSwift | Hostile text stored as data through binding; BLOB round trip; `rowLimitExceeded` instead of truncation |
| compare-and-set / compareAndSet | 0.1 | SQLiteSwift | `updated`, `conflict`, `guardFailed` with `alsoRequire`, `notFound` |
| keyset-paging / keysetPaging | 0.1 | SQLiteSwift | All rows once, in key order, with a filter |
| operation-limits / operationLimits | 0.2 | SQLiteSwift | `deadlineExceeded` and `instructionLimitExceeded` on a runaway query |
| commit-outcome / commitOutcome | 0.2 | SQLiteSwift | `writeReportingOutcome` cases; `resolveCommit` finds a pre-chosen key on a fresh connection |
| raw-bytes / rawBytes | 0.2 | SQLiteSwift | Invalid UTF-8 and NUL round trip exactly through `executeRaw`/`queryRaw` |
| file-identity / fileIdentity | 0.2 | SQLiteSwift | A file with another application ID refused with `fileIdentityMismatch` |
| error-codes / errorCodes | 0.2 | SQLiteSwift | `catch SQLiteError.Code.constraint`; `switch error.code` with `default` |
| conformance-kit / conformanceKit | 0.1 | SQLiteSwiftTesting | Three kit checks pass for the consumer's migrations (use all 13 in tests) |
| records / records | 0.9 | SQLiteSwift, SQLiteSwiftModels | `verifySchema`; insert at revision 1; update to 2; stale update and duplicate insert conflict with the current row; delete, then `missing` |
| store-stream / storeAndStream | 0.9 | SQLiteSwift, SQLiteSwiftModels | Snapshot plus stream; committed batch event with sequence and ids; rollback of a whole batch on one conflict |
| editing-context / editingContext | 0.9 | SQLiteSwift, SQLiteSwiftModels, SQLiteSwiftModelContext | One handle per record; a second context's save makes the first conflict without losing its edit; explicit `keepLocal`, then a clean save |
| backup-maintenance / backupAndMaintenance | 1.1 | SQLiteSwift | Backup with a deadline, never overwrites, `vacuum(into:)`, `quickCheck`, `optimize`; the copy opens with all rows and passes `integrityCheck` |
| observer / observeOperations | 1.1 | SQLiteSwift | An observer sees each operation's kind and outcome in order, including a failed write |
| fault-injection / faultInjection | 1.1 | SQLiteSwift, SQLiteSwiftTesting | An injected unknown commit is reported as `.unknown` and `resolveCommit` finds it not durable |
| migration-checksums / migrationChecksums | 1.1 | SQLiteSwift | With checksums on, an edited shipped migration is refused with `migrationModified` |

Copy the asset consumer into a fresh directory outside a library checkout before
running it. It resolves public HTTPS exact 1.1.0 and writes `Package.resolved` and
`.build` there. Run it in Debug and Release (`swift run -c release Consumer`);
failed checks throw and exit nonzero. A printed line is not the acceptance
predicate; the exit status is.
