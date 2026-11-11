# Third-party notices

The root LICENSE (Apache-2.0) covers original Swift-SQLite code. It does not
replace the terms of the material below.

| Material | Where | Distribution and license |
| --- | --- | --- |
| SQLite amalgamation 3.54.1 (`sqlite3.c`, `sqlite3.h`) | `Sources/CSQLiteSwift/` | Vendored byte-for-byte from https://sqlite.org/2026/sqlite-amalgamation-3540100.zip; compiled on Linux only. **Public domain.** Hashes and update steps are in [PROVENANCE.md](Sources/CSQLiteSwift/PROVENANCE.md); `Scripts/verify-amalgamation.sh` checks them. |

## SQLite public-domain dedication

All of the SQLite code and documentation is dedicated to the public domain by the
authors (https://sqlite.org/copyright.html). The amalgamation header reads:

    The author disclaims copyright to this source code.  In place of
    a legal notice, here is a blessing:

       May you do good and not evil.
       May you find forgiveness for yourself and forgive others.
       May you share freely, never taking more than you give.

On Apple platforms, SQLiteSwift links the operating system's SQLite library and
ships no SQLite code.

The package has no other third-party runtime dependencies.
