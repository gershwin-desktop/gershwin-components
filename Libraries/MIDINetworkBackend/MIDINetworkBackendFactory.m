/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkBackendFactory.h"
#import "MIDINetworkFakeBackend.h"

NSString * const MIDINetworkDefaultsDomain = @"io.github.gershwin-desktop.MIDINetwork";
NSString * const MIDINetworkDefaultsKeyBackend = @"Backend";
NSString * const MIDINetworkBackendNameSimulation = @"simulation";

id<MIDINetworkBackend> MIDINetworkBackendCreate(NSString *requestedName,
                                                id<MIDINetworkDaemonConnector> connector)
{
    if ([requestedName length] > 0) {
        if ([requestedName isEqualToString:MIDINetworkBackendNameSimulation]) {
            return [[MIDINetworkFakeBackend alloc] initWithTimers:YES];
        }
        NSString *text = [NSString stringWithFormat:@"Unknown network MIDI backend \"%@\" requested in the defaults.",
                          requestedName];
        return [[MIDINetworkUnavailableBackend alloc]
                   initWithReason:MIDINetworkMakeError(MIDINetworkErrorUnavailable, text)];
    }
    if ([connector isDaemonInstalled]) {
        return [[MIDINetworkDaemonBackend alloc] initWithConnector:connector];
    }
    return [[MIDINetworkUnavailableBackend alloc]
               initWithReason:MIDINetworkMakeError(MIDINetworkErrorUnavailable,
                                                   @"The network MIDI service is not installed.")];
}

id<MIDINetworkBackend> MIDINetworkBackendCreateDefault(void)
{
    /* Read the shared domain explicitly: the clients run inside hosts such
       as System Preferences, whose own domain is not ours to use. */
    NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:MIDINetworkDefaultsDomain];
    id requested = [domain objectForKey:MIDINetworkDefaultsKeyBackend];
    if (requested != nil && ![requested isKindOfClass:[NSString class]]) {
        requested = [requested description];
    }
    return MIDINetworkBackendCreate(requested, [[MIDINetworkDistributedObjectsConnector alloc] init]);
}
