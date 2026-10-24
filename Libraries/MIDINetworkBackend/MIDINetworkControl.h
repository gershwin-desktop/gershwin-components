/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * The control interface between network MIDI clients (the MIDI pane via
 * MIDINetworkDaemonBackend) and networkmidid, the per-user network MIDI daemon.
 * CONTROL-INTERFACE.md next to this file describes the conversation; this
 * header is its binding contract.
 *
 * Transport: Distributed Objects over NSMessagePort (Unix domain sockets
 * in the user's private GNUstep directory, so only the same user can
 * connect; works the same on Linux and the BSDs). networkmidid vends an object
 * conforming to MIDINetworkDaemonControl under MIDINetworkDaemonServiceName()
 * with the NSMessagePortNameServer.
 *
 * Every argument and result is a property list (or BOOL/int) passed
 * bycopy, using the models' and MIDINetworkState's keys, so the same
 * messages could later travel over a plain socket as JSON without
 * changing their meaning.
 */

#ifndef MIDINETWORK_CONTROL_H
#define MIDINETWORK_CONTROL_H

#import <Foundation/Foundation.h>

/* Bumped on every incompatible change; the client refuses other versions. */
#define MIDINETWORK_CONTROL_PROTOCOL_VERSION 1

/* Name of the daemon executable, installed in the SYSTEM Tools directory. */
extern NSString * const MIDINetworkDaemonToolName;

/* "io.github.gershwin-desktop.networkmidid.<uid>" for the calling user. */
NSString *MIDINetworkDaemonServiceName(void);

/* Reply and change keys. */
extern NSString * const MIDINetworkReplyKeyError;     /* failure: { code, message } */
extern NSString * const MIDINetworkReplyKeyChanges;   /* success: changed sections */
extern NSString * const MIDINetworkErrorKeyCode;
extern NSString * const MIDINetworkErrorKeyMessage;

/* Helpers both sides use to build and read replies. */
NSDictionary *MIDINetworkReplyWithError(NSError *error);
NSDictionary *MIDINetworkReplyWithChanges(NSDictionary *changes);
/* nil for a successful reply; a MIDINetworkErrorDomain error for a failed
   or malformed one. */
NSError *MIDINetworkErrorFromReply(id reply);

/* Implemented by the client and passed by reference to -registerClient:.
   A change carries one or more snapshot sections (sessions, directory,
   participants, routes, localPorts); each section present replaces that
   section of the client's copy completely. */
@protocol MIDINetworkDaemonClient
- (oneway void)daemonDidChange:(bycopy NSDictionary *)changes;
/* Asynchronous failures (a peer declined, a port was taken by another
   program, a peer timed out): { code, message }. */
- (oneway void)daemonDidEncounterError:(bycopy NSDictionary *)error;
@end

/* Vended by networkmidid. Every change returns a reply dictionary: an empty
   one or { changes } on success, { error } on failure; never nil. */
@protocol MIDINetworkDaemonControl
- (int)protocolVersion;
/* The whole state, keyed like -[MIDINetworkState propertyList]. */
- (bycopy NSDictionary *)snapshot;
- (void)registerClient:(id<MIDINetworkDaemonClient>)client;
- (void)unregisterClient:(id<MIDINetworkDaemonClient>)client;

- (bycopy NSDictionary *)addSession:(bycopy NSDictionary *)session;
- (bycopy NSDictionary *)removeSession:(bycopy NSString *)sessionIdentifier;
- (bycopy NSDictionary *)updateSession:(bycopy NSDictionary *)session;
- (bycopy NSDictionary *)setEnabled:(BOOL)enabled forSession:(bycopy NSString *)sessionIdentifier;
- (bycopy NSDictionary *)addManualHost:(bycopy NSDictionary *)host;
- (bycopy NSDictionary *)removeHost:(bycopy NSString *)hostIdentifier;
- (bycopy NSDictionary *)connectSession:(bycopy NSString *)sessionIdentifier
                                 toHost:(bycopy NSString *)hostIdentifier;
- (bycopy NSDictionary *)disconnectParticipant:(bycopy NSString *)participantIdentifier
                                   fromSession:(bycopy NSString *)sessionIdentifier;
- (bycopy NSDictionary *)setRoute:(bycopy NSDictionary *)route;
@end

#endif
