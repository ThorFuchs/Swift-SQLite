#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds one DocC archive per documented module with the toolchain's own `docc`. No
# package plugin is needed, so the package keeps zero dependencies. Any DocC warning
# fails the build. Output: .build/docs/<Module>.doccarchive
set -eu
cd "$(dirname "$0")/.."
# Use docc from PATH, or the one in the active Xcode toolchain.
DOCC="${DOCC:-$(command -v docc || xcrun --find docc)}"
MODULES="${*:-SQLiteSwift SQLiteSwiftModels SQLiteSwiftModelContext SQLiteSwiftServer}"
rm -rf .build/docs/symbols
# Every trait on, so the server bridges are documented too.
swift package --enable-all-traits --scratch-path .build/docs/build dump-symbol-graph --minimum-access-level public
for MODULE in $MODULES; do
  rm -rf ".build/docs/$MODULE.doccarchive" ".build/docs/symbols/$MODULE"
  mkdir -p ".build/docs/symbols/$MODULE"
  # The module's own graph plus the extensions it declares on other modules' types.
  find .build/docs/build -path '*symbolgraph*' -name "$MODULE.symbols.json" \
    -exec cp {} ".build/docs/symbols/$MODULE/" \; -quit
  find .build/docs/build -path '*symbolgraph*' -name "$MODULE@*.symbols.json" \
    -exec cp {} ".build/docs/symbols/$MODULE/" \;
  BUNDLE_ID="com.github.thorfuchs.$(echo "$MODULE" | tr '[:upper:]' '[:lower:]')"
  "$DOCC" convert "Sources/$MODULE/$MODULE.docc" \
    --fallback-display-name "$MODULE" \
    --fallback-bundle-identifier "$BUNDLE_ID" \
    --additional-symbol-graph-dir ".build/docs/symbols/$MODULE" \
    --warnings-as-errors \
    --output-path ".build/docs/$MODULE.doccarchive"
  echo "DocC archive: .build/docs/$MODULE.doccarchive"
done
