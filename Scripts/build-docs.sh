#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds the SwiftSQLite DocC archive with the toolchain's own `docc`. No package
# plugin is needed, so the package keeps zero dependencies. Any DocC warning fails
# the build. Output: .build/docs/SwiftSQLite.doccarchive
set -eu
cd "$(dirname "$0")/.."
rm -rf .build/docs/SwiftSQLite.doccarchive .build/docs/symbols
mkdir -p .build/docs/symbols
swift package --scratch-path .build/docs/build dump-symbol-graph --minimum-access-level public
# Only the SwiftSQLite module's graph belongs in its catalog.
find .build/docs/build -path '*symbolgraph*' -name 'SwiftSQLite.symbols.json' -exec cp {} .build/docs/symbols/ \; -quit
find .build/docs/build -path '*symbolgraph*' -name 'SwiftSQLite@*.symbols.json' -exec cp {} .build/docs/symbols/ \;
docc convert Sources/SwiftSQLite/SwiftSQLite.docc \
  --fallback-display-name SwiftSQLite \
  --fallback-bundle-identifier com.github.thorfuchs.swiftsqlite \
  --additional-symbol-graph-dir .build/docs/symbols \
  --warnings-as-errors \
  --output-path .build/docs/SwiftSQLite.doccarchive
echo "DocC archive: .build/docs/SwiftSQLite.doccarchive"
