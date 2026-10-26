/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* networkmidid stays up when the MIDI port layer cannot be opened: it
 * reports why, retries with a growing delay up to a cap, never retries a
 * problem that cannot go away, and hands over the ports once they open. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "NMDPortLayerWatcher.h"
#import "NMDMIDIPorts.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  MIDINetworkMIDISystem *missing = [MIDINetworkMIDISystem
    unavailableSystemWithProblem: MIDINetworkMIDIProblemSequencerServerNotRunning
                          device: @"/dev/snd/seq" detail: nil];
  MIDINetworkMIDISystem *noCUSE = [MIDINetworkMIDISystem
    unavailableSystemWithProblem: MIDINetworkMIDIProblemKernelLacksCUSE
                          device: @"/dev/snd/seq" detail: nil];

  START_SET("backoff")
  __block int attempts = 0, changes = 0;
  __block MIDINetworkMIDISystem *reason = missing;
  __block id ports = nil;
  NMDPortLayerWatcher *w = [[[NMDPortLayerWatcher alloc]
    initWithOpener: ^id<NMDMIDIPorts>(MIDINetworkMIDISystem **problem) {
      attempts++;
      if (ports == nil) *problem = reason;
      return (id<NMDMIDIPorts>)ports;
    } timers: NO] autorelease];
  w.changeHandler = ^{ changes++; };
  PASS(w.midiSystem == nil && w.ports == nil, "nothing is known before the start");
  [w start];
  PASS(attempts == 1 && changes == 1, "the start tries once and reports");
  PASS([w.midiSystem isEqual: missing] && w.ports == nil, "the reason is kept, there are no ports");
  PASS(w.pendingRetryDelay == 1.0, "the first retry comes after a second");

  NSMutableArray *delays = [NSMutableArray array];
  int i;
  for (i = 0; i < 7; i++)
    {
      [w retryNow];
      [delays addObject: [NSNumber numberWithDouble: w.pendingRetryDelay]];
    }
  PASS_EQUAL(delays, (@[ @2, @4, @8, @16, @30, @30, @30 ]),
    "each failure doubles the delay up to 30 s");
  PASS(changes == 1, "the same reason again is not reported again");

  reason = noCUSE;
  [w retryNow];
  PASS(changes == 2 && [w.midiSystem isEqual: noCUSE], "a different reason is reported");
  PASS(w.pendingRetryDelay == 30.0, "without resetting the delay");

  ports = [[NSObject new] autorelease];
  [w retryNow];
  PASS(w.ports == ports && w.midiSystem.available, "once the ports open they are handed over");
  PASS(changes == 3, "and that is reported");
  PASS(w.pendingRetryDelay == 0, "and no retry is pending any more");
  [w stop];
  END_SET("backoff")

  START_SET("immediate success")
  __block int changes = 0;
  id fake = [[NSObject new] autorelease];
  NMDPortLayerWatcher *w = [[[NMDPortLayerWatcher alloc]
    initWithOpener: ^id<NMDMIDIPorts>(MIDINetworkMIDISystem **problem) {
      return (id<NMDMIDIPorts>)fake;
    } timers: NO] autorelease];
  w.changeHandler = ^{ changes++; };
  [w start];
  PASS(w.ports == fake && w.midiSystem.available && changes == 1, "a working system starts at once");
  PASS(w.pendingRetryDelay == 0, "with nothing to retry");
  END_SET("immediate success")

  START_SET("permanent problem")
  __block int attempts = 0;
  MIDINetworkMIDISystem *none = [MIDINetworkMIDISystem
    unavailableSystemWithProblem: MIDINetworkMIDIProblemNoPortLayer device: nil detail: nil];
  NMDPortLayerWatcher *w = [[[NMDPortLayerWatcher alloc]
    initWithOpener: ^id<NMDMIDIPorts>(MIDINetworkMIDISystem **problem) {
      attempts++;
      *problem = none;
      return nil;
    } timers: NO] autorelease];
  [w start];
  PASS([w.midiSystem isEqual: none] && w.pendingRetryDelay == 0 && attempts == 1,
    "a system without a port layer is reported and never retried");
  END_SET("permanent problem")

  START_SET("timers")
  NMDPortLayerWatcher *w = [[[NMDPortLayerWatcher alloc]
    initWithOpener: ^id<NMDMIDIPorts>(MIDINetworkMIDISystem **problem) {
      *problem = missing;
      return nil;
    } timers: YES] autorelease];
  [w start];
  PASS(w.pendingRetryDelay == 1.0, "with timers a retry is scheduled");
  [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
  PASS(w.pendingRetryDelay == 2.0, "and the timer retries by itself");
  [w stop];
  PASS(w.pendingRetryDelay == 0, "stop cancels the retry");
  END_SET("timers")

  [arp release];
  return 0;
}
