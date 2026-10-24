/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * The interface the MIDI preference pane (and any other client) uses to
 * manage network MIDI. A backend hides where the sessions really live:
 * gwmidid, the per-user network MIDI daemon, in normal use; an in-memory
 * simulation in tests and development; or nothing at all, in which case
 * the unavailable backend says why.
 *
 * All calls happen on the main thread. Reads answer from the backend's
 * current state without blocking for long; changes return NO plus an
 * NSError in MIDINetworkErrorDomain when they are refused. Every change,
 * whether made by this client, another client or the network, is reported
 * to the delegate afterwards, so a client renders from the delegate calls
 * and never patches its own copy after a successful change.
 */

#ifndef MIDINETWORK_BACKEND_H
#define MIDINETWORK_BACKEND_H

#import <Foundation/Foundation.h>
#import "MIDINetworkModels.h"

extern NSString * const MIDINetworkErrorDomain;

typedef NS_ENUM(NSInteger, MIDINetworkErrorCode) {
    MIDINetworkErrorUnavailable = 1,      /* no network MIDI service on this system */
    MIDINetworkErrorDaemonNotRunning = 2, /* the service is installed but not reachable */
    MIDINetworkErrorPortInUse = 3,        /* another session or program owns the UDP port */
    MIDINetworkErrorPeerRejected = 4,     /* the remote side declined the invitation */
    MIDINetworkErrorTimeout = 5,          /* the daemon or the peer did not answer in time */
    MIDINetworkErrorInvalidArgument = 6   /* unknown identifier, empty name, bad port, ... */
};

/* An NSError in MIDINetworkErrorDomain with a localized description. */
NSError *MIDINetworkMakeError(MIDINetworkErrorCode code, NSString *description);
/* The same with the standard text for the code. */
NSError *MIDINetworkMakeStandardError(MIDINetworkErrorCode code);

typedef NS_ENUM(NSInteger, MIDINetworkBackendStatus) {
    MIDINetworkBackendStatusUnavailable = 0,
    MIDINetworkBackendStatusDaemonNotRunning,
    MIDINetworkBackendStatusRunning
};

@protocol MIDINetworkBackend;

@protocol MIDINetworkBackendDelegate <NSObject>
@optional
- (void)midiNetworkBackendStatusDidChange:(id<MIDINetworkBackend>)backend;
- (void)midiNetworkBackendSessionsDidChange:(id<MIDINetworkBackend>)backend;
- (void)midiNetworkBackendDirectoryDidChange:(id<MIDINetworkBackend>)backend;
/* Also sent when only a latency changed. */
- (void)midiNetworkBackend:(id<MIDINetworkBackend>)backend
    participantsDidChangeForSession:(NSString *)sessionIdentifier;
- (void)midiNetworkBackendRoutesDidChange:(id<MIDINetworkBackend>)backend;
- (void)midiNetworkBackendLocalPortsDidChange:(id<MIDINetworkBackend>)backend;
/* Failures nobody asked for synchronously, e.g. a peer leaving or an
   invitation being declined after Connect already returned. */
- (void)midiNetworkBackend:(id<MIDINetworkBackend>)backend didEncounterError:(NSError *)error;
@end

@protocol MIDINetworkBackend <NSObject>

/* Short, untranslated name for logs ("gwmidid", "simulation", ...). */
- (NSString *)backendName;

- (MIDINetworkBackendStatus)status;
/* Why the status is not Running; nil while running. */
- (NSError *)statusError;

- (id<MIDINetworkBackendDelegate>)delegate;
- (void)setDelegate:(id<MIDINetworkBackendDelegate>)delegate;

/* Begin talking to the service (connect, subscribe, browse); stop undoes
   it. A client that is not visible stops the backend so nothing polls. */
- (void)start;
- (void)stop;

#pragma mark Sessions
- (NSArray *)sessions;                                   /* MIDINetworkSession */
- (MIDINetworkSession *)sessionWithIdentifier:(NSString *)identifier;
- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error;
- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error;
/* Replaces name, advertised name, port and policy of the session with
   the same identifier; the enabled flag is changed with setEnabled:. */
- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error;
- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier
             error:(NSError **)error;

#pragma mark Directory
/* Discovered hosts and manual entries, discovered ones first. */
- (NSArray *)directory;                                  /* MIDINetworkHost */
- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error;
/* Only manual entries can be removed; discovered ones come and go with
   the network. */
- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error;

#pragma mark Connections
/* Invites the host into the session. YES means the invitation went out;
   the participant shows up (or an error arrives) through the delegate. */
- (BOOL)connectSessionWithIdentifier:(NSString *)sessionIdentifier
                toHostWithIdentifier:(NSString *)hostIdentifier
                               error:(NSError **)error;
- (NSArray *)participantsForSessionWithIdentifier:(NSString *)sessionIdentifier;
- (BOOL)disconnectParticipantWithIdentifier:(NSString *)participantIdentifier
                  fromSessionWithIdentifier:(NSString *)sessionIdentifier
                                      error:(NSError **)error;

#pragma mark Routing
- (NSArray *)localPorts;                                 /* MIDINetworkPort */
/* Never nil for a known session; directions without a port are nil. */
- (MIDINetworkRoute *)routeForSessionWithIdentifier:(NSString *)sessionIdentifier;
- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error;

@end

#endif
