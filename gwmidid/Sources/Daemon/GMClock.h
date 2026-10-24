/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#include <time.h>

/* Monotonic seconds: session timestamps and timeouts must not jump when
 * the wall clock is set. */
static inline NSTimeInterval GMMonotonicNow(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (NSTimeInterval)ts.tv_sec + (NSTimeInterval)ts.tv_nsec / 1e9;
}
