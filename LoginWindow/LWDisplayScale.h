/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#include <X11/Xlib.h>

/* Registers, for this process, the scale recommended for the PRIMARY output
 * (the first connected one when no primary is set) as GSScaleFactor. There is
 * one scale for the whole desktop, so with several monitors only the primary
 * one counts: the login window and the menu bar live there.
 *
 * Does nothing when the system-wide file (see DisplaySystemDefaults.h) is owned by the
 * user or an administrator, or when a GSScaleFactor is configured elsewhere
 * and there is no file of ours. Otherwise, with updateSystemFile, it
 * recomputes and rewrites GlobalDefaults/Display.plist with
 * GSScaleFactorSource = recommended on every start, so a new user's first
 * session gets the same scale without a per-user write. The Display pane marks
 * its own choice with GSScaleFactorSource = user, which is never overwritten.
 *
 * Must run before the first NSApplication or NSScreen use, because the
 * backend reads GSScaleFactor when it sets up the screen and the fonts.
 * Returns the registered scale, or 0.0 when nothing was registered. */
double LWRegisterRecommendedScale(Display *display, BOOL updateSystemFile);
