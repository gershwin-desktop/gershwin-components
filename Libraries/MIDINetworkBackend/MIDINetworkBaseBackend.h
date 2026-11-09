/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * What every backend shares: it answers reads from a MIDINetworkState,
 * keeps its status and delegate, and tells the delegate about changes.
 * Changes are refused with the status error until a subclass overrides
 * them, which is exactly the behaviour of a backend that cannot work.
 */

#ifndef MIDINETWORK_BASE_BACKEND_H
#define MIDINETWORK_BASE_BACKEND_H

#import "MIDINetworkBackend.h"
#import "MIDINetworkState.h"

@interface MIDINetworkBaseBackend : NSObject <MIDINetworkBackend>

@property (nonatomic, strong) MIDINetworkState *state;

/* Subclasses change the status only through this; it notifies. */
- (void)setStatus:(MIDINetworkBackendStatus)status error:(NSError *)error;

/* Refuses a change with the status error (or Unavailable without one). */
- (BOOL)refuse:(NSError **)error;

- (void)notifySessionsChanged;
- (void)notifyDirectoryChanged;
- (void)notifyParticipantsChangedForSession:(NSString *)sessionIdentifier;
- (void)notifyRoutesChanged;
- (void)notifyLocalPortsChanged;
- (void)notifyError:(NSError *)error;

@end

/* The backend of a system without network MIDI: empty, every change
   refused, statusError explains why. */
@interface MIDINetworkUnavailableBackend : MIDINetworkBaseBackend
- (instancetype)initWithReason:(NSError *)reason;
@end

#endif
