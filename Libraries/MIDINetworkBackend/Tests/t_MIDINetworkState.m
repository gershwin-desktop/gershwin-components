/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The consistency rules every backend (and gwmidid) gets from
   MIDINetworkState, and its snapshot round trip. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkState.h"
#import "MIDINetworkBackend.h"

static MIDINetworkParticipant *Participant(NSString *identifier)
{
    MIDINetworkParticipant *p = [[[MIDINetworkParticipant alloc] init] autorelease];
    p.identifier = identifier;
    p.name = identifier;
    p.address = @"10.0.0.9:5004";
    p.latency = 4.0;
    p.state = MIDINetworkParticipantStateConnected;
    return p;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSError *error = nil;

    START_SET("sessions")
    MIDINetworkState *st = [[[MIDINetworkState alloc] init] autorelease];
    PASS([st unusedPort] == 5004, "the first free port is 5004");
    MIDINetworkSession *a = [MIDINetworkSession sessionWithName:@"Session" port:5004];
    PASS([st addSession:a error:&error], "a valid session is added");
    PASS([st unusedPort] == 5006, "the next free port skips the data port of the first session");
    PASS_EQUAL([st unusedSessionNameWithBase:@"Session"], @"Session 2", "a free name is numbered");

    MIDINetworkSession *b = [MIDINetworkSession sessionWithName:@"Other" port:5005];
    error = nil;
    PASS(![st addSession:b error:&error] && [error code] == MIDINetworkErrorPortInUse,
         "a port overlapping another session's pair is refused as in use");
    b.port = 5006;
    b.name = @"session";
    error = nil;
    PASS(![st addSession:b error:&error] && [error code] == MIDINetworkErrorInvalidArgument,
         "a local name differing only in case is refused");
    b.name = @"  ";
    PASS(![st addSession:b error:NULL], "a blank local name is refused");
    b.name = @"Other";
    b.port = 80;
    PASS(![st addSession:b error:NULL], "a port below 1024 is refused");
    b.port = 5006;
    PASS([st addSession:b error:NULL], "the corrected session is added");
    PASS(![st addSession:b error:NULL], "the same identifier cannot be added twice");
    PASS([[st sessions] count] == 2, "two sessions");

    MIDINetworkSession *edit = [st sessionWithIdentifier:a.identifier];
    edit.name = @"Changed";
    PASS_EQUAL([[st sessionWithIdentifier:a.identifier] name], @"Session",
               "editing a model handed out does not change the state");
    edit.enabled = YES;
    PASS([st updateSession:edit error:NULL], "update accepts the edited session");
    PASS_EQUAL([[st sessionWithIdentifier:a.identifier] name], @"Changed", "update stores the new name");
    PASS(![[st sessionWithIdentifier:a.identifier] isEnabled], "update leaves the enabled flag alone");
    edit.port = 5007;
    PASS(![st updateSession:edit error:NULL], "update re-checks the port against the other sessions");
    END_SET("sessions")

    START_SET("participants and enabling")
    MIDINetworkState *st = [[[MIDINetworkState alloc] init] autorelease];
    MIDINetworkSession *s = [MIDINetworkSession sessionWithName:@"S" port:5004];
    [st addSession:s error:NULL];
    MIDINetworkHost *h = [MIDINetworkHost manualHostWithName:@"Peer" address:@"10.0.0.9" port:5004];
    [st addManualHost:h error:NULL];
    error = nil;
    PASS(![st validateConnectSession:s.identifier toHost:h.identifier error:&error],
         "connecting a session that is off is refused");
    PASS(![st addParticipant:Participant(@"p") toSession:s.identifier error:NULL],
         "a participant cannot join a session that is off");
    [st setEnabled:YES forSessionWithIdentifier:s.identifier error:NULL];
    PASS([st validateConnectSession:s.identifier toHost:h.identifier error:NULL], "connecting is allowed once on");
    PASS(![st validateConnectSession:s.identifier toHost:@"nope" error:NULL], "an unknown host is refused");
    PASS([st addParticipant:Participant(@"p") toSession:s.identifier error:NULL], "a participant joins");
    PASS(![st addParticipant:Participant(@"p") toSession:s.identifier error:NULL], "not twice");
    MIDINetworkParticipant *slower = Participant(@"p");
    slower.latency = 9.0;
    PASS([st replaceParticipant:slower inSession:s.identifier], "a known participant can be replaced");
    PASS([[[st participantsForSessionWithIdentifier:s.identifier] objectAtIndex:0] latency] == 9.0,
         "the new latency is stored");
    [st setEnabled:NO forSessionWithIdentifier:s.identifier error:NULL];
    PASS([[st participantsForSessionWithIdentifier:s.identifier] count] == 0,
         "turning a session off drops its participants");
    END_SET("participants and enabling")

    START_SET("directory")
    MIDINetworkState *st = [[[MIDINetworkState alloc] init] autorelease];
    MIDINetworkHost *found = [MIDINetworkHost manualHostWithName:@"Zeta" address:@"10.0.0.5" port:5004];
    [st setDiscoveredHosts:@[ found ]];
    MIDINetworkHost *manual = [MIDINetworkHost manualHostWithName:@"Alpha" address:@"10.0.0.6" port:5004];
    PASS([st addManualHost:manual error:NULL], "a manual host is added");
    NSArray *dir = [st directory];
    PASS([dir count] == 2 && [[[dir objectAtIndex:0] name] isEqual:@"Zeta"],
         "discovered hosts come before manual ones");
    PASS(![[dir objectAtIndex:0] isManual], "hosts set as discovered are marked discovered");
    error = nil;
    PASS(![st removeHostWithIdentifier:found.identifier error:&error] && error != nil,
         "a discovered host cannot be removed");
    PASS([st removeHostWithIdentifier:manual.identifier error:NULL], "a manual host can be removed");
    MIDINetworkHost *blank = [MIDINetworkHost manualHostWithName:@"X" address:@"" port:5004];
    PASS(![st addManualHost:blank error:NULL], "a host without address is refused");
    END_SET("directory")

    START_SET("routes")
    MIDINetworkState *st = [[[MIDINetworkState alloc] init] autorelease];
    MIDINetworkSession *s = [MIDINetworkSession sessionWithName:@"S" port:5004];
    [st addSession:s error:NULL];
    [st setLocalPorts:@[ [MIDINetworkPort portWithIdentifier:@"kbd" name:@"Keyboard" canSend:YES canReceive:NO],
                         [MIDINetworkPort portWithIdentifier:@"syn" name:@"Synth" canSend:NO canReceive:YES] ]];
    MIDINetworkRoute *r = [st routeForSessionWithIdentifier:s.identifier];
    PASS(r != nil && r.inputPortIdentifier == nil && r.outputPortIdentifier == nil,
         "a session starts unrouted, and the route is not nil");
    PASS([st routeForSessionWithIdentifier:@"nope"] == nil, "an unknown session has no route");
    PASS(![st setRoute:[MIDINetworkRoute routeForSession:s.identifier inputPort:@"syn" outputPort:nil] error:NULL],
         "a port that cannot send is refused as input");
    PASS(![st setRoute:[MIDINetworkRoute routeForSession:s.identifier inputPort:nil outputPort:@"kbd"] error:NULL],
         "a port that cannot receive is refused as output");
    PASS([st setRoute:[MIDINetworkRoute routeForSession:s.identifier inputPort:@"kbd" outputPort:@"syn"] error:NULL],
         "a matching route is stored");
    [st setLocalPorts:@[ [MIDINetworkPort portWithIdentifier:@"syn" name:@"Synth" canSend:NO canReceive:YES] ]];
    r = [st routeForSessionWithIdentifier:s.identifier];
    PASS(r.inputPortIdentifier == nil && [r.outputPortIdentifier isEqual:@"syn"],
         "a port that disappears is removed from the route, the other direction stays");

    /* Snapshot round trip with everything filled in. */
    [st setEnabled:YES forSessionWithIdentifier:s.identifier error:NULL];
    [st addParticipant:Participant(@"p") toSession:s.identifier error:NULL];
    [st setDiscoveredHosts:@[ [MIDINetworkHost manualHostWithName:@"Found" address:@"10.0.0.7" port:5004] ]];
    NSDictionary *snap = [st propertyList];
    MIDINetworkState *back = [MIDINetworkState stateWithPropertyList:snap];
    PASS_EQUAL([back propertyList], snap, "a snapshot round trip gives the same state");
    NSMutableDictionary *broken = [[snap mutableCopy] autorelease];
    [broken setObject:@{ s.identifier: @[ @{ @"name": @"x" } ] } forKey:MIDINetworkStateKeyParticipants];
    PASS([MIDINetworkState stateWithPropertyList:broken] == nil, "a malformed participant rejects the snapshot");
    [broken removeObjectForKey:MIDINetworkStateKeyParticipants];
    PASS([MIDINetworkState stateWithPropertyList:broken] == nil, "a missing section rejects the snapshot");
    PASS([st removeSessionWithIdentifier:s.identifier error:NULL], "removing the session works");
    PASS([[st participantsForSessionWithIdentifier:s.identifier] count] == 0
         && [[[st propertyList] objectForKey:MIDINetworkStateKeyRoutes] count] == 0,
         "removing a session removes its participants and route");
    END_SET("routes")

    [arp release];
    return 0;
}
