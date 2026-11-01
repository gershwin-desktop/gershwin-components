/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 *
 * Reading and changing the X11Forwarding directive of an sshd_config.
 * Plain C without GNUstep so that the privileged sharing-helper can use it.
 */

#ifndef SSHD_X11_H
#define SSHD_X11_H

#include <stddef.h>

/* Returns the text of the idx-th file that the Include pattern matches
 * (malloc'd, NUL terminated), or NULL when there is no idx-th file. */
typedef char *(*SshdIncludeLoader)(const char *pattern, int idx, void *ctx);

/* Called with the path of the new, not yet installed config file; returns 0
 * when the daemon accepts it. */
typedef int (*SshdConfigValidator)(const char *path, void *ctx);

/* The loader the helper uses: glob(3) on the pattern, relative patterns
 * resolved against the directory in ctx (a const char *), files sorted the
 * way sshd reads them. */
char *sshd_x11_glob_loader(const char *pattern, int idx, void *ctx);

/* Value sshd would use for new connections outside Match blocks.  The first
 * occurrence wins, Include files are read where the Include stands, and no
 * directive means "no".  Returns 0 on success, -1 with a message in err when
 * the layout is not understood. */
int sshd_x11_effective(const char *text, SshdIncludeLoader load, void *ctx,
                       int *enabled, char *err, size_t errlen);

/* Builds the text with X11Forwarding set to enable, touching nothing but that
 * one directive.  *out is malloc'd and equals text when nothing had to
 * change.  Returns 0, or -1 with a message in err (nothing allocated) when
 * the directive cannot be changed safely, e.g. because an included file
 * decides the value. */
int sshd_x11_edit(const char *text, SshdIncludeLoader load, void *ctx,
                  int enable, char **out, char *err, size_t errlen);

/* Reads path, applies sshd_x11_edit and replaces the file atomically with the
 * original owner and mode.  Include patterns are resolved against dirname of
 * path.  validate (may be NULL) must accept the new file before it replaces
 * the old one.  *changed is 0 when the file already had the wanted value. */
int sshd_x11_rewrite_file(const char *path, int enable,
                          SshdConfigValidator validate, void *vctx,
                          int *changed, char *err, size_t errlen);

/* Same for reading the effective value of the file at path. */
int sshd_x11_read_file(const char *path, int *enabled, char *err, size_t errlen);

#endif
