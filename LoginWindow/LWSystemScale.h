/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The system-wide scale file, GlobalDefaults/Display.plist beside the system
 * GNUstep.conf. libs-base merges it into the config domain of every process,
 * below the user's own defaults. Format:
 *
 *   { GSScaleFactor = <real>; GSScaleFactorSource = recommended | user; }
 *
 * "recommended": written by LoginWindow from the primary monitor's size; it
 * recomputes and rewrites it on every start, so a first boot in a VM, on a
 * projector or docked does not pin the scale.
 * "user": written by the Display pane through the privileged helper; nobody
 * else touches it. A file with a scale but no source is treated the same way,
 * because an administrator wrote it.
 * Owner root, mode 0644 (libs-base ignores files others can write). */
extern NSString * const LWSystemDisplayDefaultsFileName;
extern NSString * const LWScaleSourceKey;
extern NSString * const LWScaleSourceRecommended;
extern NSString * const LWScaleSourceUser;

typedef NS_ENUM(NSInteger, LWSystemScaleState) {
    LWSystemScaleAbsent,       // no file, or one that does not parse
    LWSystemScaleRecommended,  // ours: may be replaced
    LWSystemScaleConfigured    // the user's or an administrator's: leave alone
};

/* Directory libs-base reads GlobalDefaults from (GNUSTEP_CONFIG_FILE moves it). */
NSString *LWSystemDefaultsDirectory(void);

LWSystemScaleState LWSystemScaleStateInDirectory(NSString *directory);

/* Replaces the file with scale and source "recommended" unless the state is
 * LWSystemScaleConfigured. Creates the directory (0755) if missing and writes
 * through a temporary file and rename. Returns NO and logs on failure. */
BOOL LWWriteRecommendedScale(NSString *directory, double scale);
