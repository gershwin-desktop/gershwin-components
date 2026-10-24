/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#ifndef MIDINETWORK_BACKEND_FACTORY_H
#define MIDINETWORK_BACKEND_FACTORY_H

#import "MIDINetworkBackend.h"
#import "MIDINetworkDaemonBackend.h"

/* Defaults domain and key that ask for the simulation instead of gwmidid:
     defaults write io.github.gershwin-desktop.MIDINetwork Backend simulation
   Meant for working on clients without a daemon; nothing sets it. */
extern NSString * const MIDINetworkDefaultsDomain;
extern NSString * const MIDINetworkDefaultsKeyBackend;
extern NSString * const MIDINetworkBackendNameSimulation;

/* The decision itself, with its inputs passed in so tests can walk it:
   "simulation" requested -> the fake backend; gwmidid installed -> its
   backend (DaemonNotRunning until it answers); otherwise an unavailable
   backend whose statusError says the service is not installed. Any other
   requested name is refused with an unavailable backend that names it,
   rather than silently using something else. */
id<MIDINetworkBackend> MIDINetworkBackendCreate(NSString *requestedName,
                                                id<MIDINetworkDaemonConnector> connector);

/* MIDINetworkBackendCreate with the user default and the Distributed
   Objects connector. Never nil. */
id<MIDINetworkBackend> MIDINetworkBackendCreateDefault(void);

#endif
