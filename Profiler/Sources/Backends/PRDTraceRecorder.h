/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorder.h"

/* CPU time and heap allocations on the BSDs that ship DTrace (FreeBSD,
   NetBSD): the profile provider samples stacks, the pid provider weighs
   the allocation calls by their size. DTrace aggregates the stacks itself,
   so a recording has no time axis. */
@interface PRDTraceRecorder : PRRecorder
@end
