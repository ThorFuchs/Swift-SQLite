# Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no such module 'SQLite'` | Wrong module name. This package's module is `SQLiteSwift`. |
| `invalid conversion of thrown error type 'any Error' to 'SQLiteError'` | The closure needs the typed form `{ tx throws(SQLiteError) in … }`, and every call inside must throw `SQLiteError`. |
| `converting non-Sendable function value to '@Sendable …'` | A closure stored in a variable needs an explicit `@Sendable (SQLiteTransaction) throws(SQLiteError) -> T` type. |
| `reference to captured var … in concurrently-executing code` | Transaction closures are `@Sendable`. Capture a `let` copy (`[value]`) instead of a `var`. |
| `'await' in a function that does not support concurrency` inside a transaction | Transaction closures are synchronous; move the async work outside. |
| `invalidConfiguration` for an in-memory database | Use `SQLiteConfiguration.inMemory()` (one connection). |
| `schemaTooNew` at open | The file was migrated by newer code. Don't delete migrations; ship the newer migrations or open a copy. |
| `rowLimitExceeded` / `resultTooLarge` | Results are never truncated. Page with `queryPage`, select fewer columns, or set a finite larger limit if the task needs it. |
| `busy` | Another connection holds the write lock past the busy timeout. Retry the operation later; keep transactions short. |
| `commitOutcomeUnknown` | Resolve with `resolveCommit` using a key written in the failed transaction. Never retry blindly. |
| An API from this kit doesn't exist | The consumer resolves an older version; check [versions](versions.md). Don't upgrade silently. |
| Pattern match on `SQLitePredicate` cases fails | Since 0.9.0 it's a struct; build predicates with the static functions only. |
