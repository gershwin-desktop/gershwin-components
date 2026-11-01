/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class PRMemoryMap;

/* Asks the system where a process's memory sits. Nothing is injected into
   the process and nothing is recorded beforehand, so this works on a program
   that has been running for days, which is when a leak is usually noticed. */
@interface PRMemoryMapReader : NSObject

/* Returns nil when the system does not let us look, and says why. */
+ (PRMemoryMap *)mapForProcess:(pid_t)pid error:(NSError **)error;

/* Whether this system reports how much of each mapping is really in RAM.
   Where it does not, only the claimed address space can be shown. */
+ (BOOL)reportsResidentMemoryPerMapping;

@end
