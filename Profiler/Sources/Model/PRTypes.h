/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PR_TYPES_H
#define PR_TYPES_H

#import <Foundation/Foundation.h>

/* What one unit of cost in a profile means. */
typedef enum {
    PRCostUnitSamples = 0,   /* CPU samples; weight 1 per sample */
    PRCostUnitBytes,         /* heap bytes */
    PRCostUnitAllocations    /* number of allocation calls */
} PRCostUnit;

/* How the flat list folds symbols together. */
typedef enum {
    PRGroupingFunction = 0,
    PRGroupingClass,
    PRGroupingModule,
    PRGroupingThread
} PRGrouping;

/* Half open time window in seconds on the recording's own clock. */
typedef struct {
    double start;
    double end;
} PRTimeRange;

static inline PRTimeRange PRTimeRangeAll(void)
{
    PRTimeRange r;
    r.start = -INFINITY;
    r.end = INFINITY;
    return r;
}

static inline BOOL PRTimeRangeIsAll(PRTimeRange r)
{
    return r.start == -INFINITY && r.end == INFINITY;
}

static inline BOOL PRTimeRangeContains(PRTimeRange r, double t)
{
    return t >= r.start && t <= r.end;
}

/* Threads are selected by id; this value means "all threads". */
#define PR_ALL_THREADS ((int32_t)-1)

#endif
