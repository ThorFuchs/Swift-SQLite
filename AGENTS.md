# Working on Swift-SQLite

Instructions for coding agents and contributors working **on this repository**.
For help *using* the library in another project, see the developer kit
([Documentation/AgentDeveloperKit.md](Documentation/AgentDeveloperKit.md)).

## Ground rules

- The core module is `SQLiteSwift`. It has no package dependencies and must keep
  none. The model layer (`SQLiteSwiftModels`, `SQLiteSwiftModelContext`) builds on
  the core's public API; the core never imports it.
- The public API is frozen for 1.0.0. Don't break source compatibility;
  `Scripts/check-api.sh` compares against the latest tag.
- Swift 6.4, language mode 6, strict concurrency, typed throws. Transaction closures
  are synchronous and `@Sendable`; nothing runs on the cooperative pool.
- Locks use `SQLiteLocked` (pthread), not `Synchronization.Mutex`: ThreadSanitizer
  on Linux can't see Mutex, also in tests.
- Never modify the vendored SQLite amalgamation (`Sources/CSQLiteSwift`); see its
  PROVENANCE.md.
- Tests use Swift Testing, barriers instead of sleeps, and temporary directories
  from `SQLiteSwiftTesting`.

## Before a pull request

```text
swift test
swift test --sanitize=thread
Scripts/build-docs.sh                    # every public symbol documented, warnings are errors
Scripts/check-api.sh
python3 Scripts/validate_developer_kit.py
Scripts/run_kit_recipes.sh               # the kit's recipes against this checkout
```

Update `CHANGELOG.md` for user-visible changes. Pull requests target `main`, which
is protected: the five CI checks must pass. Read CONTRIBUTING.md for the rest.
