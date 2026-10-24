/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_GMLatencyEstimator - the latency shown for a participant is robust
 * against single spikes (a WLAN station waking from power save). */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GMLatencyEstimator.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  GMLatencyEstimator *e = [[GMLatencyEstimator new] autorelease];

  PASS([e estimate] < 0, "no measurement yet: negative");
  [e addSample: 0.490];
  PASS(EQ([e estimate], 0.490), "a single measurement is all there is");
  [e addSample: 0.0012];
  PASS(EQ([e estimate], 0.0012), "of two, the lower middle value wins over the spike");
  [e addSample: 0.0023];
  [e addSample: 0.0018];
  [e addSample: 0.0020];
  PASS(EQ([e estimate], 0.0020), "median of the last five ignores one 490 ms spike");
  PASS(EQ([e lastSample], 0.0020), "the raw last value stays available");
  [e addSample: 0.0500];
  [e addSample: 0.0600];
  PASS(EQ([e estimate], 0.0023), "only the last five count: the spike has left the window");
  [e addSample: 0.0700];
  [e addSample: 0.0800];
  PASS(EQ([e estimate], 0.0600), "a lasting change is followed within three syncs");
  PASS([e sampleCount] == 5, "the window holds five samples");

  [arp release];
  return 0;
}
