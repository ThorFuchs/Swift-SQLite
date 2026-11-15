#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds and runs the benchmark package in release mode. The JSON result goes to
# stdout, a readable summary to stderr. Results depend on the machine and its
# storage; compare runs on the same machine only.
set -eu
cd "$(dirname "$0")/../Benchmarks"
swift run -c release --scratch-path ../.build/benchmarks SQLiteSwiftBenchmarks
