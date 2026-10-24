/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The interface gwmidid vends over Distributed Objects under the name
 * io.github.gershwin-desktop.gwmidid on the per-user message port name
 * server, so only processes of the same user reach it.  Everything is
 * passed by copy as property-list types.  Mutators return nil on success
 * and an error message otherwise.  After every change gwmidid posts
 * io.github.gershwin-desktop.gwmidid.StatusDidChange on the distributed
 * notification center.
 *
 * -daemonStatus returns:
 *   PortLayer    string
 *   Sessions     array of { Name, Port, Enabled, Announce, Policy,
 *                Running (bool), Error (string, when not running),
 *                MIDIPort ("client:port" of the session's MIDI port),
 *                Participants: array of { Identifier, Name, Address,
 *                  Role (initiator|responder), State, LatencyMs } }
 *   Directory    array of { Name, Host, Port }
 *   Discovered   array of { Name, HostName, Addresses, Port }
 *   Errors       array of strings: configuration entries that were refused
 */
@protocol GMDaemonControl

- (bycopy NSDictionary *) daemonStatus;

- (bycopy NSString *) addSession: (bycopy NSDictionary *)configuration;
- (bycopy NSString *) updateSession: (bycopy NSString *)name
                  withConfiguration: (bycopy NSDictionary *)configuration;
- (bycopy NSString *) removeSession: (bycopy NSString *)name;

- (bycopy NSString *) setDirectoryEntries: (bycopy NSArray *)entries;

/* target: a directory entry name, an announced service name, or
 * "host:port" with a numeric host */
- (bycopy NSString *) connectSession: (bycopy NSString *)name
                                  to: (bycopy NSString *)target;
- (bycopy NSString *) disconnectParticipant: (bycopy NSString *)identifier
                                  inSession: (bycopy NSString *)name;

@end
