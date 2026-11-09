/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorder.h"

/* CPU time on Linux: samples stacks with perf(1) and decodes them with
   "perf script". */
@interface PRPerfRecorder : PRRecorder

/* The kernel refuses to sample for unprivileged users depending on
   kernel.perf_event_paranoid; this is what it is set to, or -1 when it
   cannot be read. */
+ (int)perfEventParanoid;

@end
