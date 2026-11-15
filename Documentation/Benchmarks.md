# Benchmarks

A small, dependency-free suite in [`Benchmarks/`](../Benchmarks) (a separate package,
so the library's dependency graph stays empty). Run it with:

```sh
Scripts/run-benchmarks.sh > result.json
```

Each case opens a fresh file database with the default configuration (WAL, one
writer and four readers, `synchronous=FULL`, and on Apple platforms `F_FULLFSYNC`),
runs one warm-up and five measured rounds, and reports the median, minimum and
maximum. Compare runs on the same machine and storage only.

## Baseline for 1.0.0

Recorded 15 November 2026 on an Apple M1 Max (10 cores, 32 GB, internal SSD),
macOS 27.3, Swift 6.4.2, release build. Raw data:
[2026-11-15-m1-max-macos-27.3.json](../Benchmarks/Baselines/2026-11-15-m1-max-macos-27.3.json).

| Case | Operations | Median | Throughput |
| --- | --- | --- | --- |
| Durable single-row transactions (insert, commit each) | 500 | 251 ms | ~2,000 commits/s |
| Rows inserted in one transaction | 50,000 | 90 ms | ~555,000 rows/s |
| Point reads, one read transaction each, 8 concurrent tasks | 20,000 | 224 ms | ~89,000 reads/s |
| Keyset scan, 500 rows per page | 10,000 | 3.8 ms | ~2.6 million rows/s |
| Compare-and-set updates, one transaction each | 500 | 158 ms | ~3,200 updates/s |
| Model layer: managed batches of 10 inserts through a store | 2,000 | 116 ms | ~17,000 records/s |

## Reading the numbers

- **Commits are bound by the disk's flush.** Every single-row transaction waits for
  a durable `COMMIT`. These cases vary most between runs (in one round the slowest
  was three times the median) and between machines. Batch work into fewer
  transactions when throughput matters; `synchronous=NORMAL` is an explicit opt-in
  that trades durability of the last transactions for speed.
- **Work inside a transaction is cheap.** Bound statements come from the statement
  cache; the bulk insert shows the cost per row without the flush.
- **Reads scale over the reader pool.** Each point read is its own snapshot
  transaction on a reader thread.
- The model layer adds a sequence update, the existence check and a read-back per
  record, and still commits each batch once.

These numbers are a reference for regressions, not a guarantee.
