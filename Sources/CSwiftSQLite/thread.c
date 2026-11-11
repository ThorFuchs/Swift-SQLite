// SPDX-License-Identifier: Apache-2.0
// Linux thread-naming wrappers; see include/cswiftsqlite_thread.h.

#if defined(__linux__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <pthread.h>
#include <string.h>
#include "cswiftsqlite_thread.h"

int cswiftsqlite_set_current_thread_name(const char *name) {
    char truncated[16];
    strncpy(truncated, name, sizeof(truncated) - 1);
    truncated[sizeof(truncated) - 1] = '\0';
    return pthread_setname_np(pthread_self(), truncated);
}

int cswiftsqlite_get_current_thread_name(char *buffer, size_t length) {
    return pthread_getname_np(pthread_self(), buffer, length);
}
#else
typedef int cswiftsqlite_thread_unused_on_this_platform;
#endif
