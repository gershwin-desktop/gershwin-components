/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The per-user display configuration: one stored layout per set of
 * connected monitors, and the decisions around it (which layout to apply
 * for the monitors that are connected now, whether the server already runs
 * it).  Shared by the Display pane and the displayconfig tool, which the
 * window manager runs at login and whenever monitors come or go.
 * Foundation only, so every decision has a headless test. */

#import <Foundation/Foundation.h>

@class DisplayLayout;

/* NSUserDefaults persistent domain holding the layouts: configuration key
 * (-[DisplayLayout configurationKey]) -> -[DisplayLayout propertyList]. */
extern NSString * const DisplayLayoutsDomain;

@interface DisplayLayoutStore : NSObject
{
    NSString *_domainName;
}

/* The store of the user running the process. */
+ (instancetype)userStore;
/* A store in another persistent domain (tests). */
- (instancetype)initWithDomainName:(NSString *)domainName;

/* The layout saved for a configuration key, or nil. */
- (DisplayLayout *)layoutForKey:(NSString *)key;
/* Saves `layout` under its own configuration key, replacing an earlier one
 * for the same monitors.  NO when the defaults could not be written. */
- (BOOL)saveLayout:(DisplayLayout *)layout;
/* Every saved layout, key -> DisplayLayout. */
- (NSDictionary *)allLayouts;

@end

/* `saved` (a stored layout for the same set of monitors) laid onto the
 * outputs connected now.  Monitors are matched by EDID identity, so a
 * monitor that moved to another connector keeps its place; outputs without
 * EDID are matched by connector name.  The result keeps the server details
 * of `current` (connector names, mode lists, CRTCs).  nil when the saved
 * layout does not fit (a monitor is missing, or a stored mode is not in the
 * output's list any more); then *problem says why. */
DisplayLayout *DisplayResolveSavedLayout(DisplayLayout *saved,
                                         DisplayLayout *current,
                                         NSString **problem);

/* The layout for monitors nobody has arranged yet.  Outputs the server
 * already lights stay as they are (no mode switch at login), and every dark
 * output is added to the right at its preferred mode, the way a newly
 * attached monitor extends the desktop.  Outputs that overlap without
 * mirroring exactly (the server's own clone-at-0,0 start) are spread out
 * side by side at their preferred modes, the primary first.  A primary is
 * always set. */
DisplayLayout *DisplayDefaultLayout(DisplayLayout *current);

/* YES when applying `wanted` would change anything on a server that runs
 * `current`: which outputs are lit, their mode (size and refresh within
 * the 0.5 Hz the mode selection allows), position, transform, rotation and
 * the primary.  Applying when nothing differs would still make the server
 * announce a RandR change, which the window manager answers by applying
 * again; this check keeps that from looping. */
BOOL DisplayLayoutsDiffer(DisplayLayout *wanted, DisplayLayout *current);

/* System-wide defaults that LoginWindow (and every user without an own
 * value) reads: GlobalDefaults/Display.plist beside the GNUstep.conf
 * libs-base loaded. */
NSString *DisplaySystemDefaultsPath(void);
/* The file content: `existing` (may be nil) with GSScaleFactor replaced, so
 * keys written by others survive. */
NSDictionary *DisplaySystemDefaultsBySettingScale(NSDictionary *existing,
                                                  double scale);
/* Writes the system defaults at `path` with GSScaleFactor set to `scale`,
 * atomically and with mode 0644: libs-base ignores a defaults file that
 * group or others can write.  NO with *problem when it cannot. */
BOOL DisplayWriteSystemScale(NSString *path, double scale, NSString **problem);
