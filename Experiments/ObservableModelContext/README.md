# Observable model-context research spike

This branch contains a test-only, article-specific feasibility prototype in `Tests/SQLiteSwiftTests/ObservableSpikeTests.swift`. It is not a production API or an integration into SQLiteSwift. Its purpose is to explore Sendable snapshots, revision-checked transactions, generic main-actor Observation, explicit saves and conflict behavior.

The prototype tests conditional inserts and updates, revision-checked deletes, batch rollback, conflict snapshots and explicit resolution, edits during a suspended save, overlapping saves, cancellation before SQLite work, and simulated unknown-commit outcomes. It prevents ID reuse in its experimental schema with a permanent registry and insert trigger. Commit recovery writes a marker in the same transaction and probes it through `resolveCommit`. Writers must preserve both the revision contract and the identity registry.

On Linux x86_64, Swift 6.4.2, the unmodified baseline passed 84 tests; the full suite including the prototype passed 97 tests. Run:

```sh
swift build
swift test --filter ObservableSpikeTests
swift test
```

The unknown-commit tests inject errors before a write and after a known successful write; they do not simulate actual I/O failure during COMMIT. The context supports manual refresh only, not a transaction-aware change stream. Context inserts and deletes, marker retention and cleanup, process-restart recovery, migration of existing data, real COMMIT fault injection, and macOS/system SQLite verification remain open. The identity registry grows permanently and privileged SQL can defeat it by changing the trigger or registry. The code has not been evaluated for production use.
