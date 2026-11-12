# Contributing to Swift-SQLite

Thank you for helping. Bug reports, documentation fixes and focused pull requests are
all welcome.

## Before you start

- For a bug, open an issue with the version, platform and a minimal reproduction.
- For a new feature or an API change, open an issue first so we can agree on the
  design. The package follows [Semantic Versioning](README.md#versioning): after
  1.0.0, a source-breaking change needs a new major version.
- Security problems go through [private reporting](SECURITY.md), not issues.

## Development

Requirements: Swift 6.4 (Xcode 27 on macOS), or the Swift 6.4 toolchain on Linux.

```sh
swift build
swift test
swift test --sanitize=thread
Scripts/build-docs.sh            # DocC; warnings are errors
Scripts/verify-amalgamation.sh   # the vendored SQLite matches upstream
swift package diagnose-api-breaking-changes <last-tag>
```

## Guidelines

- **Zero dependencies.** The package depends on nothing but the toolchain.
- **Swift 6 language mode**, strict concurrency, typed throws (`throws(SQLiteError)`).
- **No blocking work on the cooperative thread pool.** SQLite calls run on the
  connection's own thread.
- **Every public symbol is documented.** DocC builds with warnings as errors.
- **Every behavior has a test.** New guarantees also belong in the conformance kit
  when consumers should verify them in their own setups.
- **Errors are typed.** Add a `SQLiteError.Code` instead of reusing an unrelated one.
- **Opt-in, never silent.** New behavior arrives as an option or profile; existing
  defaults don't change in a minor release.
- Each source file starts with `// SPDX-License-Identifier: Apache-2.0`.

## Pull requests

- Keep each pull request to one change, with tests and a CHANGELOG entry under
  "Unreleased".
- CI must pass on macOS and Linux (x86_64 and arm64).
- By contributing, you agree that your contribution is licensed under the
  [Apache License 2.0](LICENSE), the license of this project.

## Code of conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
