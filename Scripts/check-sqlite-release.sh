#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Compares the vendored SQLite amalgamation with the latest release on sqlite.org.
# Prints "current=<version> latest=<version> url=<archive URL>" and exits 0 when
# they match, 10 when a newer release exists, and 1 on any error. It only reads;
# updating the amalgamation stays a reviewed change (see PROVENANCE.md).
set -eu
cd "$(dirname "$0")/.."
CURRENT="$(sed -n 's/^| Version | \([0-9][0-9.]*\) .*/\1/p' Sources/CSQLiteSwift/PROVENANCE.md)"
[ -n "$CURRENT" ] || { echo "error: no version in PROVENANCE.md" >&2; exit 1; }
LINE="$(curl -fsSL --max-time 30 https://sqlite.org/download.html | grep -oE 'PRODUCT,[0-9.]+,[0-9]+/sqlite-amalgamation-[0-9]+\.zip' | head -1)"
[ -n "$LINE" ] || { echo "error: no amalgamation entry on sqlite.org/download.html" >&2; exit 1; }
LATEST="$(echo "$LINE" | cut -d, -f2)"
URL="https://sqlite.org/$(echo "$LINE" | cut -d, -f3)"
echo "current=$CURRENT latest=$LATEST url=$URL"
[ "$CURRENT" = "$LATEST" ] && exit 0
NEWEST="$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[ "$NEWEST" = "$LATEST" ] && exit 10
echo "error: sqlite.org lists $LATEST, older than the vendored $CURRENT" >&2
exit 1
