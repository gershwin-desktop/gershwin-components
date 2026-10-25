/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#include <X11/Xlib.h>

/* The system-wide defaults file the Display pane writes through the
 * privileged helper and every GNUstep process reads on its own: libs-base
 * merges every plist file in GlobalDefaults beside the system GNUstep.conf into
 * the config domain, which ranks below the user's own defaults. Keys:
 * GSScaleFactor (real). */
extern NSString * const LWSystemDisplayDefaultsFileName;

/* Registers the scale recommended for the primary monitor as GSScaleFactor
 * for this process, unless a GSScaleFactor is configured anywhere (the system
 * wide GlobalDefaults or this user's defaults). Must run before the first
 * NSApplication or NSScreen use, because the backend reads GSScaleFactor when
 * it sets up the screen and the fonts. Returns the registered scale, or 0.0
 * when nothing was registered. */
double LWRegisterRecommendedScale(Display *display);

/* Writes the system-wide defaults file with scale, so a new user's first
 * session starts with the same scale as the login window without a per-user
 * write. Does nothing when the file exists. Returns NO and logs the reason
 * when the directory is not writable (a read-only /System). */
BOOL LWSeedSystemScale(double scale);
