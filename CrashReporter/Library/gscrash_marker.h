/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSCrashMarker_h
#define GSCrashMarker_h

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Minimal, async-signal-safe crash marker writer.
 *
 * This is called from a signal handler. It must NOT allocate via malloc, must
 * not call Objective-C runtime, must not take arbitrary locks. It writes a
 * small JSON marker to <markersDir>/<pid>-<monotonic>.marker using only the
 * open/write/close syscalls over stack buffers.
 *
 * Returns 0 on success, -1 on failure (errno set).
 */
int gscrash_write_signal_marker(const char *markersDir,
                                const char *appName,
                                const char *execPath,
                                pid_t pid,
                                uid_t uid,
                                const char *signalName,
                                const char *exceptionName,
                                const char *exceptionReason,
                                const char *buildID);

#ifdef __cplusplus
}
#endif

#endif /* GSCrashMarker_h */
