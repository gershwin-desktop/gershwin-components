/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * A simulated network MIDI service for tests and for working on the pane
 * without a network or a daemon. It keeps sessions in memory, "discovers"
 * a few hosts after the first simulation step, lets invitations be
 * accepted one step later (except by the host named
 * MIDINetworkFakeRejectingHostName, which declines), and lets the latency
 * of connected participants wander a little on every step.
 *
 * With timers (the default) a step runs every second on the main run
 * loop; tests create it without timers and call -advanceSimulation, so
 * every outcome is deterministic.
 */

#ifndef MIDINETWORK_FAKE_BACKEND_H
#define MIDINETWORK_FAKE_BACKEND_H

#import "MIDINetworkBaseBackend.h"

extern NSString * const MIDINetworkFakeRejectingHostName;

/* Operation names for -failNextOperation:withCode:. */
extern NSString * const MIDINetworkFakeOperationAddSession;
extern NSString * const MIDINetworkFakeOperationRemoveSession;
extern NSString * const MIDINetworkFakeOperationUpdateSession;
extern NSString * const MIDINetworkFakeOperationSetEnabled;
extern NSString * const MIDINetworkFakeOperationAddManualHost;
extern NSString * const MIDINetworkFakeOperationRemoveHost;
extern NSString * const MIDINetworkFakeOperationConnect;
extern NSString * const MIDINetworkFakeOperationDisconnect;
extern NSString * const MIDINetworkFakeOperationSetRoute;

@interface MIDINetworkFakeBackend : MIDINetworkBaseBackend

- (instancetype)initWithTimers:(BOOL)useTimers;

/* One simulation step: discovery, invitation answers, latency changes. */
- (void)advanceSimulation;

/* The next call of that operation fails with the standard error of code,
   once. */
- (void)failNextOperation:(NSString *)operation withCode:(MIDINetworkErrorCode)code;

/* Pretend the daemon stopped or came back. */
- (void)setSimulatedDaemonRunning:(BOOL)running;

/* A peer leaving on its own, as the network would report it. */
- (void)simulateParticipant:(NSString *)participantIdentifier
          leavingSession:(NSString *)sessionIdentifier;

@end

#endif
