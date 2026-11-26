/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "MIDINetworkControl.h"

/* Ties the pieces together for one user: the sessions with their sockets
 * and MIDI ports, the mDNS directory, the routes to local ports, the
 * timers, and the control interface of CONTROL-INTERFACE.md in
 * Libraries/MIDINetworkBackend.  The configuration lives in a
 * MIDINetworkState, so the rules are those the MIDI pane knows. */
@interface NMDDaemon : NSObject <MIDINetworkDaemonControl>

/* Fails only when another networkmidid of this user runs.  Without the MIDI
 * system (no sequencer device) it keeps running, reports why through the
 * control interface, refuses changes and starts the sessions once the
 * sequencer appears; sessions that cannot start are logged and stay
 * disabled. */
- (BOOL) startWithError: (NSString **)error;

/* Ends every session with BY and withdraws the announcements. */
- (void) shutdown;

@end
