#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Verifies that the vendored SQLite amalgamation is byte-identical to the pinned
# upstream release (see Sources/CSQLiteSwift/PROVENANCE.md).
set -eu
cd "$(dirname "$0")/.."
if command -v sha256sum >/dev/null 2>&1; then
  SHA="sha256sum"
else
  SHA="shasum -a 256"
fi
check() {
  actual=$($SHA "$2" | cut -d' ' -f1)
  if [ "$actual" != "$1" ]; then
    echo "MISMATCH $2: expected $1, got $actual" >&2
    exit 1
  fi
  echo "OK $2 $actual"
}
check 0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52 Sources/CSQLiteSwift/sqlite3.c
check d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c Sources/CSQLiteSwift/include/sqlite3.h
