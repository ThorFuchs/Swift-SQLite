# SQLite amalgamation provenance

| Field | Value |
| --- | --- |
| Product | SQLite amalgamation |
| Version | 3.54.1 (`SQLITE_VERSION_NUMBER` 3054001) |
| Source URL | https://sqlite.org/2026/sqlite-amalgamation-3540100.zip |
| Archive SHA3-256 (as published on sqlite.org/download.html) | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` |
| Archive SHA-256 | `0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9` |
| `sqlite3.c` SHA-256 | `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52` |
| `include/sqlite3.h` SHA-256 | `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c` |
| Retrieved | 2026-11-11 |
| License | Public domain (see below) |

## What is vendored

- `sqlite3.c` and `include/sqlite3.h` are byte-for-byte copies from the archive.
  They are not modified. `Scripts/verify-amalgamation.sh` checks both hashes, and CI
  runs it.
- `shell.c` and `sqlite3ext.h` from the same archive are not vendored. The package
  does not build the CLI or loadable extensions.
- `shim.c` is original to this package. It includes `sqlite3.c` only when
  `__linux__` is defined. Apple platforms link the system SQLite (`import SQLite3`).
- Compile options are preprocessor defines in `Package.swift` (`cSettings`). The
  package has no `unsafeFlags`.

## Public-domain notice

The SQLite source code is in the public domain. The amalgamation's own header reads:

> The author disclaims copyright to this source code. In place of a legal notice,
> here is a blessing: May you do good and not evil. May you find forgiveness for
> yourself and forgive others. May you share freely, never taking more than you give.

See https://sqlite.org/copyright.html.

## Updating

1. Download the new amalgamation zip from https://sqlite.org/download.html into an
   empty scratch directory.
2. Check its SHA3-256 against the value on the download page.
3. Copy `sqlite3.c` and `sqlite3.h` without changes, then update this table, the
   hashes in `Scripts/verify-amalgamation.sh`, `THIRD_PARTY_NOTICES.md` and the
   CHANGELOG.
