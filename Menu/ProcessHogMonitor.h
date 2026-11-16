/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Finds the processes that hog the machine, for the Force Quit panel: those
 * using more than 95% of one CPU core between two samples, or more than 50%
 * of physical memory.  Feed it successive process tables (ProcessInfo records
 * from ProcessSampler); it keeps the previous one to measure CPU against.
 * It touches no process itself, so it is testable with hand-made tables. */
@interface ProcessHogMonitor : NSObject

/* Percent of ONE core, so a process pinning a single core reads 100 whatever
 * the number of cores - the question is "is something stuck in a loop". */
+ (double)cpuThresholdPercent;
+ (double)memoryThresholdPercent;

- (instancetype)initWithTotalMemoryKB:(long)totalMemoryKB
                       ticksPerSecond:(long)ticksPerSecond
                          currentUser:(NSString *)currentUser
                               ownPid:(int)ownPid;

/* Takes the table read at "time" (seconds, any monotonic origin) and returns
 * the hogs: dictionaries with "name", "pid" (NSNumber), "reason" (e.g.
 * "98% CPU"), "cpu" and "memory" (NSNumber percentages).  The first table
 * after creation can only judge memory. */
- (NSArray *)hogsAfterSample:(NSArray *)processes atTime:(NSTimeInterval)time;

/* The rows of the panel: the applications by name, then the hogs that are not
 * one of them by name.  Each row has "name", "pid", "detail" (the reason, or
 * empty) and "application" (NSNumber BOOL).  An application that is also a
 * hog stays one row and carries the reason as its detail. */
+ (NSArray *)rowsForApplications:(NSArray *)applications hogs:(NSArray *)hogs;

@end
