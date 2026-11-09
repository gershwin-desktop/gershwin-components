/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Shared by the test tools (each tool is its own program, so defining a
   class here is fine): a delegate that counts what a backend reported. */

#import <Foundation/Foundation.h>
#import "MIDINetworkBackend.h"

@interface MNRecorder : NSObject <MIDINetworkBackendDelegate>
{
@public
    int status, sessions, directory, participants, routes, ports, errors;
    NSError *lastError;
}
- (void)reset;
@end

@implementation MNRecorder
- (void)reset
{
    status = sessions = directory = participants = routes = ports = errors = 0;
    [lastError release];
    lastError = nil;
}
- (void)dealloc
{
    [lastError release];
    [super dealloc];
}
- (void)midiNetworkBackendStatusDidChange:(id<MIDINetworkBackend>)b { status++; }
- (void)midiNetworkBackendSessionsDidChange:(id<MIDINetworkBackend>)b { sessions++; }
- (void)midiNetworkBackendDirectoryDidChange:(id<MIDINetworkBackend>)b { directory++; }
- (void)midiNetworkBackend:(id<MIDINetworkBackend>)b participantsDidChangeForSession:(NSString *)s { participants++; }
- (void)midiNetworkBackendRoutesDidChange:(id<MIDINetworkBackend>)b { routes++; }
- (void)midiNetworkBackendLocalPortsDidChange:(id<MIDINetworkBackend>)b { ports++; }
- (void)midiNetworkBackend:(id<MIDINetworkBackend>)b didEncounterError:(NSError *)e
{
    errors++;
    [lastError release];
    lastError = [e retain];
}
@end
