/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The system-wide scale file, GlobalDefaults/Display.plist beside the system
 * GNUstep.conf. libs-base merges it into the config domain of every process,
 * below the user's own defaults, so LoginWindow and every user without an own
 * GSScaleFactor start with it. Format:
 *
 *   { GSScaleFactor = <real>; GSScaleFactorSource = recommended | user; }
 *
 * "recommended": written by LoginWindow from the primary monitor's size; it
 * recomputes and rewrites it on every start, so a first boot in a VM, on a
 * projector or docked does not pin the scale.
 * "user": written by displayconfig write-system-scale (as root) when the user
 * picks a scale in the Display pane; nobody else touches it. A file with a
 * scale but no source is treated the same way, because an administrator
 * wrote it.
 * Owner root, mode 0644 (libs-base ignores files others can write).
 *
 * Foundation only: LoginWindow, displayconfig and the unit tests build this
 * one file, so the readers and writers can never disagree about the format. */
extern NSString * const DisplaySystemDefaultsFileName;
extern NSString * const DisplayScaleFactorKey;
extern NSString * const DisplayScaleSourceKey;
extern NSString * const DisplayScaleSourceRecommended;
extern NSString * const DisplayScaleSourceUser;

typedef NS_ENUM(NSInteger, DisplaySystemScaleState) {
    DisplaySystemScaleAbsent,       // no file, one without a scale, or one that does not parse
    DisplaySystemScaleRecommended,  // LoginWindow's: may be replaced
    DisplaySystemScaleConfigured    // the user's or an administrator's: leave alone
};

/* Directory libs-base reads GlobalDefaults from (GNUSTEP_CONFIG_FILE moves it,
 * as in the isolated test sessions), or nil when it is unknown. */
NSString *DisplaySystemDefaultsDirectory(void);
/* GlobalDefaults/Display.plist in that directory, or nil. */
NSString *DisplaySystemDefaultsPath(void);

DisplaySystemScaleState DisplaySystemScaleStateAtPath(NSString *path);

/* The file content: `existing` (may be nil) with the scale and its source
 * replaced, so keys written by others survive. */
NSDictionary *DisplaySystemDefaultsBySettingScale(NSDictionary *existing,
                                                  double scale,
                                                  NSString *source);

/* Writes `scale` with `source` into the file at `path`, keeping other keys.
 * Creates the directory (0755) when it is missing, and writes through a
 * temporary file and a rename with mode 0644 whatever the umask, so a
 * process starting meanwhile never reads half a file and libs-base does not
 * ignore it. NO with *problem (may be NULL) when it cannot. */
BOOL DisplayWriteSystemScale(NSString *path, double scale, NSString *source,
                             NSString **problem);

/* LoginWindow's write: as DisplayWriteSystemScale with source "recommended",
 * but a configured file is left alone (and that is not a failure). */
BOOL DisplayWriteRecommendedScale(NSString *path, double scale,
                                  NSString **problem);
