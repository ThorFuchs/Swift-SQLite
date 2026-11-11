// SPDX-License-Identifier: Apache-2.0
//
// Compiles the pinned, unmodified SQLite amalgamation (sqlite3.c, excluded from the
// target's own source list) on Linux only. Apple platforms use the system SQLite,
// so this translation unit is intentionally empty there.

#if defined(__linux__)
#include "sqlite3.c"
#else
typedef int csqliteswift_unused_on_this_platform;
#endif
