/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "MIDINetworkModels.h"

@protocol NMDMIDIPorts;

/* Opens the port layer, or returns nil and sets *problem. */
typedef id<NMDMIDIPorts> (^NMDPortsOpener)(MIDINetworkMIDISystem **problem);

/* Gets the MIDI port layer open.  When it cannot be opened (no sequencer
 * device yet, alsa-seq-server not started) networkmidid must stay up and
 * say why rather than exit, or its supervisor restarts it in a tight loop.
 * Retries are spaced 1, 2, 4, ... seconds apart up to 30 s, so a sequencer
 * that comes up later is found within half a minute at no idle cost; a
 * system without any port layer is never retried. */
@interface NMDPortLayerWatcher : NSObject

/* timers: NO for tests, which call -retryNow instead of waiting. */
- (instancetype) initWithOpener: (NMDPortsOpener)opener timers: (BOOL)timers;

/* nil until the layer is open. */
@property (nonatomic, readonly) id<NMDMIDIPorts> ports;
/* nil before -start; available once the ports are open. */
@property (nonatomic, readonly) MIDINetworkMIDISystem *midiSystem;
/* Seconds until the pending retry; 0 when none is pending. */
@property (nonatomic, readonly) NSTimeInterval pendingRetryDelay;
/* Called when midiSystem changes, including when the ports open; not for
 * a retry that fails for the same reason as before. */
@property (nonatomic, copy) void (^changeHandler)(void);

- (void) start;
- (void) retryNow;
- (void) stop;

@end
