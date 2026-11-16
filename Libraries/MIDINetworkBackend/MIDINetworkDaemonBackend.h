/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * The backend for networkmidid, the per-user network MIDI daemon. It keeps the
 * daemon's last snapshot in its state, forwards changes over the control
 * interface (MIDINetworkControl.h) and applies the change sections the
 * daemon sends back or pushes. While the daemon cannot be reached the
 * status is DaemonNotRunning and the connection is retried every few
 * seconds, so the pane comes alive by itself once the daemon starts.
 */

#ifndef MIDINETWORK_DAEMON_BACKEND_H
#define MIDINETWORK_DAEMON_BACKEND_H

#import "MIDINetworkBaseBackend.h"
#import "MIDINetworkControl.h"

/* How the backend reaches the daemon; tests substitute an in-process
   daemon object for the Distributed Objects connection. */
@protocol MIDINetworkDaemonConnector <NSObject>
- (BOOL)isDaemonInstalled;
/* The vended control object, or nil when the daemon does not answer. */
- (id<MIDINetworkDaemonControl>)connect;
/* Called with the connected control object; the connector calls
   lostBlock once when that connection dies. */
- (void)watchControl:(id<MIDINetworkDaemonControl>)control lost:(void (^)(void))lostBlock;
- (void)disconnectControl:(id<MIDINetworkDaemonControl>)control;
@end

/* networkmidid in the SYSTEM Tools directory, reached over NSMessagePort. */
@interface MIDINetworkDistributedObjectsConnector : NSObject <MIDINetworkDaemonConnector>
@end

@interface MIDINetworkDaemonBackend : MIDINetworkBaseBackend <MIDINetworkDaemonClient>

- (instancetype)initWithConnector:(id<MIDINetworkDaemonConnector>)connector;

/* Seconds between connection attempts while the daemon is not reachable;
   0 turns retrying off (tests call -start again instead). */
@property (nonatomic) NSTimeInterval retryInterval;

@end

#endif
