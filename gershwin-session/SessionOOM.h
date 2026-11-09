/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
/*
 * Which supervised apps stay protected from the kernel's OOM killer.
 *
 * The root step that starts the session (LoginWindow.sh) gives LoginWindow,
 * and through it Xorg and the whole user session, a low oom_score_adj.  The
 * value is inherited across fork and exec, so every app the supervisor
 * starts would get it too.  Only the desktop's core has to survive memory
 * pressure; every other app is handed back to the kernel's normal choice
 * (oom_score_adj 0), so that the app using the most memory is the one that
 * goes.
 */
#ifndef GERSHWIN_SESSION_OOM_H
#define GERSHWIN_SESSION_OOM_H

/* Nonzero when the app named (a bare name or a path) is part of the
 * desktop's core and keeps the session's protection. */
int GSSessionIsCoreApp(const char *name);

/* The oom_score_adj a supervised app is started with, as the text the
 * kernel file takes, or NULL when it keeps the supervisor's own value. */
const char *GSSessionOOMScoreAdjForApp(const char *name);

/* Writes value to the oom_score_adj file at path.  Returns 0, or -1 with
 * errno set.  Uses only async-signal-safe calls, so a child may call it
 * between fork and exec. */
int GSSessionWriteOOMScoreAdj(const char *path, const char *value);

#endif
