#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Compares the public API with the latest release tag (or the tag given as $1).
# From 1.0.0 on, any source-breaking change fails. Before 1.0.0, changes are
# reported as a warning, because 0.x releases may break the API.
set -eu
cd "$(dirname "$0")/.."
BASELINE="${1:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
if [ -z "$BASELINE" ]; then
  echo "No release tag yet; nothing to compare."
  exit 0
fi
echo "Comparing the public API with $BASELINE"
if swift package diagnose-api-breaking-changes "$BASELINE"; then
  exit 0
fi
MAJOR="${BASELINE%%.*}"
if [ "$MAJOR" -ge 1 ]; then
  echo "error: source-breaking API changes against $BASELINE need a new major version."
  exit 1
fi
echo "::warning::Source-breaking API changes against $BASELINE (allowed before 1.0.0)."
