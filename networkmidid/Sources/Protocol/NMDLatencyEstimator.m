/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDLatencyEstimator.h"

/* Few enough that a lasting change shows after three syncs, enough that
 * one or two spikes never do. */
#define NMD_LATENCY_WINDOW 5

@implementation NMDLatencyEstimator
{
  NSMutableArray *_samples;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    _samples = [NSMutableArray array];
  return self;
}

- (void) addSample: (NSTimeInterval)latency
{
  [_samples addObject: @(latency)];
  if ([_samples count] > NMD_LATENCY_WINDOW) [_samples removeObjectAtIndex: 0];
}

- (NSTimeInterval) estimate
{
  NSArray *sorted;
  if ([_samples count] == 0) return -1.0;
  sorted = [_samples sortedArrayUsingSelector: @selector(compare:)];
  return [[sorted objectAtIndex: ([sorted count] - 1) / 2] doubleValue];
}

- (NSTimeInterval) lastSample
{
  return [_samples count] ? [[_samples lastObject] doubleValue] : -1.0;
}

- (NSUInteger) sampleCount
{
  return [_samples count];
}

@end
