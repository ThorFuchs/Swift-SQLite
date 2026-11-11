// SPDX-License-Identifier: Apache-2.0
//
// Thread-naming helpers for Linux. glibc declares pthread_setname_np and
// pthread_getname_np only under _GNU_SOURCE, which Swift's Glibc module does not
// set, so SQLiteSwift calls these wrappers instead. Implemented in thread.c
// (Linux only).
#ifndef CSWIFTSQLITE_THREAD_H
#define CSWIFTSQLITE_THREAD_H

#include <stddef.h>

/// Names the calling thread (truncated to 15 bytes). Returns 0 on success.
int csqliteswift_set_current_thread_name(const char *name);

/// Copies the calling thread's name into buffer. Returns 0 on success.
int csqliteswift_get_current_thread_name(char *buffer, size_t length);

#endif
