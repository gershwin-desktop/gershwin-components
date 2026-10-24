/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The simulation backend, stepped by hand: discovery, invitations,
   latency, a declining peer, injected failures and a stopped daemon. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkFakeBackend.h"
#import "MIDINetworkTestSupport.h"

static MIDINetworkHost *HostNamed(id<MIDINetworkBackend> b, NSString *name)
{
    for (MIDINetworkHost *h in [b directory]) {
        if ([h.name isEqual:name]) {
            return h;
        }
    }
    return nil;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSError *error = nil;
    MNRecorder *rec = [[MNRecorder new] autorelease];
    MIDINetworkFakeBackend *b = [[[MIDINetworkFakeBackend alloc] initWithTimers:NO] autorelease];
    [b setDelegate:rec];

    START_SET("status")
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning, "before start the service is not running");
    PASS(![b addSession:[MIDINetworkSession sessionWithName:@"S" port:5004] error:&error]
         && [error code] == MIDINetworkErrorDaemonNotRunning, "changes before start are refused");
    [b start];
    PASS([b status] == MIDINetworkBackendStatusRunning && [b statusError] == nil, "start makes it run");
    PASS(rec->status == 1, "the delegate hears about the status change");
    PASS([[b localPorts] count] == 3, "there are simulated local ports");
    PASS([[b directory] count] == 0, "nothing is discovered before the first step");
    [b advanceSimulation];
    PASS([[b directory] count] == 3 && rec->directory == 1, "the first step discovers three hosts");
    END_SET("status")

    MIDINetworkSession *s = [MIDINetworkSession sessionWithName:@"Session" port:5004];
    START_SET("sessions")
    [rec reset];
    PASS([b addSession:s error:NULL] && rec->sessions == 1, "adding a session notifies");
    PASS([[b sessions] count] == 1, "the session is listed");
    MIDINetworkHost *laptop = HostNamed(b, @"Studio Laptop");
    error = nil;
    PASS(![b connectSessionWithIdentifier:s.identifier toHostWithIdentifier:laptop.identifier error:&error]
         && [error code] == MIDINetworkErrorInvalidArgument, "connecting a session that is off is refused");
    PASS([b setEnabled:YES forSessionWithIdentifier:s.identifier error:NULL], "the session is turned on");
    PASS([[b sessionWithIdentifier:s.identifier] isEnabled], "it reads back as on");
    END_SET("sessions")

    START_SET("connecting")
    [rec reset];
    MIDINetworkHost *laptop = HostNamed(b, @"Studio Laptop");
    PASS([b connectSessionWithIdentifier:s.identifier toHostWithIdentifier:laptop.identifier error:NULL],
         "an invitation goes out");
    NSArray *parts = [b participantsForSessionWithIdentifier:s.identifier];
    PASS([parts count] == 1 && ![[parts objectAtIndex:0] isConnected], "the peer is listed as being invited");
    PASS(rec->participants == 1, "the delegate hears about it");
    [b advanceSimulation];
    MIDINetworkParticipant *p = [[b participantsForSessionWithIdentifier:s.identifier] objectAtIndex:0];
    PASS([p isConnected] && p.latency >= 1.0 && p.latency <= 20.0, "one step later it is connected with a latency");
    double first = p.latency;
    BOOL moved = NO;
    int i;
    [rec reset];
    for (i = 0; i < 5; i++) {
        [b advanceSimulation];
        p = [[b participantsForSessionWithIdentifier:s.identifier] objectAtIndex:0];
        moved = moved || p.latency != first;
    }
    PASS(moved && rec->participants == 5, "the latency changes over the steps and each step notifies");

    [rec reset];
    MIDINetworkHost *busy = HostNamed(b, MIDINetworkFakeRejectingHostName);
    PASS([b connectSessionWithIdentifier:s.identifier toHostWithIdentifier:busy.identifier error:NULL],
         "inviting the busy host is accepted at first");
    [b advanceSimulation];
    PASS(rec->errors == 1 && [rec->lastError code] == MIDINetworkErrorPeerRejected,
         "its refusal arrives later as a peer-rejected error");
    PASS([[b participantsForSessionWithIdentifier:s.identifier] count] == 1, "and it is not left in the list");

    PASS([b disconnectParticipantWithIdentifier:p.identifier fromSessionWithIdentifier:s.identifier error:NULL],
         "disconnecting works");
    PASS([[b participantsForSessionWithIdentifier:s.identifier] count] == 0, "the list is empty again");
    PASS(![b disconnectParticipantWithIdentifier:p.identifier fromSessionWithIdentifier:s.identifier error:NULL],
         "disconnecting twice is refused");
    END_SET("connecting")

    START_SET("routing")
    [rec reset];
    MIDINetworkRoute *r = [MIDINetworkRoute routeForSession:s.identifier inputPort:@"fake:keyboard"
                                                 outputPort:@"fake:synth"];
    PASS([b setRoute:r error:NULL] && rec->routes == 1, "a route is set and notified");
    PASS_EQUAL([b routeForSessionWithIdentifier:s.identifier], r, "it reads back");
    END_SET("routing")

    START_SET("injected failures")
    [b failNextOperation:MIDINetworkFakeOperationAddSession withCode:MIDINetworkErrorTimeout];
    MIDINetworkSession *t = [MIDINetworkSession sessionWithName:@"Second" port:5006];
    error = nil;
    PASS(![b addSession:t error:&error] && [error code] == MIDINetworkErrorTimeout, "the injected failure happens");
    PASS([b addSession:t error:NULL], "only once");
    MIDINetworkHost *m = [MIDINetworkHost manualHostWithName:@"Manual" address:@"10.1.1.1" port:5004];
    PASS([b addManualHost:m error:NULL] && [HostNamed(b, @"Manual") isManual], "a manual host is added");
    PASS([b removeHostWithIdentifier:m.identifier error:NULL] && HostNamed(b, @"Manual") == nil,
         "and removed");
    PASS([b removeSessionWithIdentifier:t.identifier error:NULL], "the second session is removed");
    END_SET("injected failures")

    START_SET("daemon stops")
    [rec reset];
    [b setSimulatedDaemonRunning:NO];
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning && rec->status == 1, "the stop is reported");
    error = nil;
    PASS(![b removeSessionWithIdentifier:s.identifier error:&error]
         && [error code] == MIDINetworkErrorDaemonNotRunning, "changes are refused while it is stopped");
    [b setSimulatedDaemonRunning:YES];
    PASS([b removeSessionWithIdentifier:s.identifier error:NULL], "and work again once it is back");
    [b stop];
    END_SET("daemon stops")

    [arp release];
    return 0;
}
