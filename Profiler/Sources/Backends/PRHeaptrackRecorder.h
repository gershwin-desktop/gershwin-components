/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorder.h"

/* Heap memory on Linux: records every allocation with heaptrack and turns
   the result into weighted stacks with heaptrack_print. */
@interface PRHeaptrackRecorder : PRRecorder
@end
