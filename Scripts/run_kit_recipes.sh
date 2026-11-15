#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds and runs the developer kit's recipe consumer in Debug and Release.
#
#   Scripts/run_kit_recipes.sh           against this checkout (CI, every PR)
#   Scripts/run_kit_recipes.sh --tag     against the published tag the kit pins
#
# The consumer is copied to a fresh temporary directory first, so nothing is written
# into the skill. A failed recipe throws and exits nonzero in both configurations.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/plugins/swift-sqlite/skills/swift-sqlite/assets/consumer"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/swift-sqlite-kit-recipes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp -R "$SOURCE/." "$WORK/"
if [ "${1:-}" != "--tag" ]; then
  # Same products, resolved from this checkout instead of the published tag.
  sed -i.bak "s#.package(url: \"https://github.com/ThorFuchs/Swift-SQLite.git\", exact: \"[0-9.]*\")#.package(name: \"Swift-SQLite\", path: \"$ROOT\")#" "$WORK/Package.swift"
  rm -f "$WORK/Package.swift.bak"
  grep -q "path: \"$ROOT\"" "$WORK/Package.swift" || { echo "error: could not point the consumer at $ROOT"; exit 1; }
fi
for CONFIG in debug release; do
  echo "== recipes ($CONFIG)"
  swift run --package-path "$WORK" -c "$CONFIG" Consumer
done
