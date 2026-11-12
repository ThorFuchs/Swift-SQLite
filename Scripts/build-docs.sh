#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds the SQLiteSwift DocC archive with the toolchain's own `docc`. No package
# plugin is needed, so the package keeps zero dependencies. Any DocC warning fails
# the build. Output: .build/docs/SQLiteSwift.doccarchive
set -eu
cd "$(dirname "$0")/.."
# Use docc from PATH, or the one in the active Xcode toolchain.
DOCC="${DOCC:-$(command -v docc || xcrun --find docc)}"
rm -rf .build/docs/SQLiteSwift.doccarchive .build/docs/symbols
mkdir -p .build/docs/symbols
swift package --scratch-path .build/docs/build dump-symbol-graph --minimum-access-level public
# Only the SQLiteSwift module's graph belongs in its catalog.
find .build/docs/build -path '*symbolgraph*' -name 'SQLiteSwift.symbols.json' -exec cp {} .build/docs/symbols/ \; -quit
find .build/docs/build -path '*symbolgraph*' -name 'SQLiteSwift@*.symbols.json' -exec cp {} .build/docs/symbols/ \;
"$DOCC" convert Sources/SQLiteSwift/SQLiteSwift.docc \
  --fallback-display-name SQLiteSwift \
  --fallback-bundle-identifier com.github.thorfuchs.sqliteswift \
  --additional-symbol-graph-dir .build/docs/symbols \
  --warnings-as-errors \
  --output-path .build/docs/SQLiteSwift.doccarchive
echo "DocC archive: .build/docs/SQLiteSwift.doccarchive"
