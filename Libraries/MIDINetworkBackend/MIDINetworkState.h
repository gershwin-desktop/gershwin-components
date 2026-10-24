/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * Everything a network MIDI service knows at one moment, with the rules
 * that keep it consistent (unique ports, non-empty names, participants
 * only in enabled sessions, routes only to existing ports).
 *
 * The simulation backend keeps one of these as its whole world; the
 * gwmidid client keeps the daemon's last snapshot in one; and gwmidid can
 * link this class to hold its own configuration, so that the rules a user
 * meets are the same in tests, in development and in the real service.
 * Foundation only, main thread only.
 */

#ifndef MIDINETWORK_STATE_H
#define MIDINETWORK_STATE_H

#import <Foundation/Foundation.h>
#import "MIDINetworkModels.h"

/* Snapshot keys of -propertyList, also used by the control interface. */
extern NSString * const MIDINetworkStateKeySessions;
extern NSString * const MIDINetworkStateKeyDirectory;
extern NSString * const MIDINetworkStateKeyParticipants;
extern NSString * const MIDINetworkStateKeyRoutes;
extern NSString * const MIDINetworkStateKeyLocalPorts;

/* UDP ports a session may use: the data port is port + 1, and ports
   below 1024 need root, which a per-user service does not have. */
#define MIDINETWORK_MIN_PORT 1024
#define MIDINETWORK_MAX_PORT 65534
#define MIDINETWORK_DEFAULT_PORT 5004

@interface MIDINetworkState : NSObject

/* nil if the snapshot is malformed in any part. */
+ (instancetype)stateWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;

- (NSArray *)sessions;
- (MIDINetworkSession *)sessionWithIdentifier:(NSString *)identifier;
- (NSArray *)directory;            /* discovered first, then manual, each by name */
- (MIDINetworkHost *)hostWithIdentifier:(NSString *)identifier;
- (NSArray *)participantsForSessionWithIdentifier:(NSString *)identifier;
- (NSArray *)localPorts;
- (MIDINetworkPort *)localPortWithIdentifier:(NSString *)identifier;
- (MIDINetworkRoute *)routeForSessionWithIdentifier:(NSString *)identifier;

/* The lowest even port >= MIDINETWORK_DEFAULT_PORT no session uses. */
- (NSUInteger)unusedPort;
/* "Session", "Session 2", ... not yet taken by a session. */
- (NSString *)unusedSessionNameWithBase:(NSString *)base;

/* Mutators: NO plus an error in MIDINetworkErrorDomain when refused, and
   then nothing has changed. */
- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error;
- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error;
/* Disabling drops the session's participants. */
- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier error:(NSError **)error;

- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error;
- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error;
/* Replaces the discovered part of the directory; manual entries stay. */
- (void)setDiscoveredHosts:(NSArray *)hosts;

/* Checks that the session exists and is enabled; used before inviting. */
- (BOOL)validateConnectSession:(NSString *)sessionIdentifier
                        toHost:(NSString *)hostIdentifier error:(NSError **)error;
- (BOOL)addParticipant:(MIDINetworkParticipant *)participant
             toSession:(NSString *)sessionIdentifier error:(NSError **)error;
- (BOOL)removeParticipantWithIdentifier:(NSString *)participantIdentifier
                            fromSession:(NSString *)sessionIdentifier error:(NSError **)error;
/* Latency or state of a known participant; NO when it is gone. */
- (BOOL)replaceParticipant:(MIDINetworkParticipant *)participant inSession:(NSString *)sessionIdentifier;

/* Ports that disappear are also removed from every route. */
- (void)setLocalPorts:(NSArray *)ports;
- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error;

@end

#endif
