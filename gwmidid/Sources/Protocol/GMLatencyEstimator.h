/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The latency shown for a participant.  A single clock sync can take
 * hundreds of milliseconds when a WLAN station wakes from power save; the
 * median of the last few measurements does not jump with it but still
 * follows a lasting change within a few syncs. */
@interface GMLatencyEstimator : NSObject

/* Seconds, one-way */
- (void) addSample: (NSTimeInterval)latency;

/* Median of the last five samples (the lower middle one of an even
 * number), negative before the first. */
- (NSTimeInterval) estimate;

/* The newest raw sample, negative before the first */
- (NSTimeInterval) lastSample;

- (NSUInteger) sampleCount;

@end
