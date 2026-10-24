/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* The CPU/power governor backend behind both the Energy preference pane and
 * the Battery menu extra.  Kept as one class, compiled from this single
 * source into both targets, so the list of governors, the current one and
 * how a change is applied never drifts between the two places that show it. */
@interface CPUGovernorBackend : NSObject

/* Governors this host can switch between, in the OS's own native order
 * (Linux: whatever scaling_available_governors reports; the BSDs: a fixed
 * policy set, since they do not name governors the way Linux cpufreq does). */
+ (NSArray<NSString *> *)availableGovernors;

/* The governor active right now, or nil if this host cannot report one. */
+ (NSString *)currentGovernor;

/* Switches to the named governor; returns whether the OS accepted it. */
+ (BOOL)setGovernor:(NSString *)governor;

/* Pure parse of Linux's whitespace-separated scaling_available_governors
 * line, split out so it can be exercised without a real /sys tree. */
+ (NSArray<NSString *> *)parseAvailableGovernorsFromSysfsList:(NSString *)raw;

/* Index of `governor` in `governors` (exact match), or NSNotFound - the
 * check-mark decision a menu needs, kept pure so it can be tested without
 * touching hardware. */
+ (NSUInteger)indexOfGovernor:(NSString *)governor inList:(NSArray<NSString *> *)governors;

@end
