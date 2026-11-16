/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

/* Reads the process table, however the system offers it: /proc, then sysctl,
 * then "ps".  Foundation only, so the Processes application and Menu's Force
 * Quit panel share one reader instead of each carrying its own. */
@interface ProcessSampler : NSObject

/* One ProcessInfo per process with raw readings (cumulative CPU ticks,
 * resident memory); percentages are derived from two samples by the caller.
 * *truncated is set when the scan hit its time budget and the list is
 * incomplete. */
+ (NSArray *)scanProcessesTruncated:(BOOL *)truncated;

/* Physical memory in KB, 0 when the system does not say. */
+ (long)totalMemoryKB;

/* The name the scan reports as owner of a process, so that a caller can
 * compare it with the owner of the current process. */
+ (NSString *)userNameForUid:(uid_t)uid;

@end
