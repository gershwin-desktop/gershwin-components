/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDPortLayerWatcher.h"
#import "NMDMIDIPorts.h"

#define NMD_FIRST_RETRY 1.0
#define NMD_MAX_RETRY 30.0

@implementation NMDPortLayerWatcher
{
  NMDPortsOpener _opener;
  BOOL _timers;
  NSTimer *_timer;
}

- (instancetype) initWithOpener: (NMDPortsOpener)opener timers: (BOOL)timers
{
  if ((self = [super init]) != nil)
    {
      _opener = [opener copy];
      _timers = timers;
    }
  return self;
}

- (void) dealloc
{
  [_timer invalidate];
}

- (void) start
{
  [self attempt];
}

- (void) retryNow
{
  [_timer invalidate];
  _timer = nil;
  [self attempt];
}

- (void) stop
{
  [_timer invalidate];
  _timer = nil;
  _pendingRetryDelay = 0;
}

- (void) attempt
{
  MIDINetworkMIDISystem *problem = nil;
  MIDINetworkMIDISystem *before = _midiSystem;
  id<NMDMIDIPorts> ports;

  if (_ports != nil) return;
  ports = _opener(&problem);
  if (ports != nil)
    {
      _ports = ports;
      _midiSystem = [MIDINetworkMIDISystem availableSystem];
      [self stop];
    }
  else
    {
      _midiSystem = problem;
      [self scheduleRetryFor: problem];
    }
  if (![_midiSystem isEqual: before] && _changeHandler != nil)
    _changeHandler();
}

- (void) scheduleRetryFor: (MIDINetworkMIDISystem *)problem
{
  /* Nothing on this system will ever provide a port layer, so waiting
   * would only cost wakeups. */
  if ([problem.problem isEqual: MIDINetworkMIDIProblemNoPortLayer])
    {
      [self stop];
      return;
    }
  _pendingRetryDelay = (_pendingRetryDelay == 0)
    ? NMD_FIRST_RETRY : MIN(_pendingRetryDelay * 2, NMD_MAX_RETRY);
  if (_timers)
    _timer = [NSTimer scheduledTimerWithTimeInterval: _pendingRetryDelay
                                              target: self
                                            selector: @selector(timerFired:)
                                            userInfo: nil
                                             repeats: NO];
}

- (void) timerFired: (NSTimer *)timer
{
  _timer = nil;
  [self attempt];
}

@end
