/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class PRProcessInfo;

/* Lists the running processes and keeps track of how much CPU and memory
   each of them uses, so a target can be picked by what it is doing right
   now. CPU use is a difference between two readings, so the first reading
   of a process reports zero. */
@interface PRProcessMonitor : NSObject
{
    NSMutableDictionary *_previousTicks;
    NSMutableDictionary *_previousTime;
}

- (NSArray *)processes;
- (PRProcessInfo *)processWithIdentifier:(pid_t)pid;

@end
