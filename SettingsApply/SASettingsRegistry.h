/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "SASetting.h"

/* Which pane settings are re-applied at login and in what order, and the
 * decision which of them to apply for a given set of defaults.  Kept free of
 * any backend so the decision can be tested without touching the system. */
@interface SASettingsRegistry : NSObject

/* Every re-applied setting, in the order they must be applied (a keyboard
 * layout before the key swap on top of it, the mouse speed before the
 * trackpad speed that overrides it for the touchpad, as the panes do). */
+ (NSArray<SASetting *> *)settings;

/* The defaults domains the settings live in, each once. */
+ (NSArray<NSString *> *)domains;

/* The Mouse pane once stored scrolling, handedness and the trackpad curve
 * under shared keys; those are moved to the per-class keys (see
 * MousePreferences) so a user who has not opened the pane since still gets
 * them back. */
+ (NSDictionary<NSString *, NSDictionary *> *)domainsByMigrating:(NSDictionary<NSString *, NSDictionary *> *)domains;

/* domains maps a domain name to its persistent domain dictionary; a domain
 * or key that is missing means the user never set it, so that setting is
 * skipped rather than applied with some default value. */
+ (NSArray<SAPlannedApply *> *)planForSettings:(NSArray<SASetting *> *)settings
                                       domains:(NSDictionary<NSString *, NSDictionary *> *)domains;

@end
