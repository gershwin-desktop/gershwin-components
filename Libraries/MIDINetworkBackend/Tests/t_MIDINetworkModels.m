/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The models survive a property-list round trip, also through a real
   serialisation, and malformed lists are rejected as a whole. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkModels.h"

static id ThroughXML(id plist)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:NULL];
    return [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("session")
    MIDINetworkSession *s = [MIDINetworkSession sessionWithName:@"Studio" port:5004];
    PASS([s.identifier length] > 0, "a new session gets an identifier");
    PASS(!s.enabled && s.policy == MIDINetworkConnectionPolicyAnyone, "a new session is off and open to anyone");
    PASS_EQUAL(s.advertisedName, @"Studio", "the advertised name starts as the local name");
    s.enabled = YES;
    s.policy = MIDINetworkConnectionPolicyDirectoryOnly;
    s.advertisedName = @"Studio Desk";
    MIDINetworkSession *back = [MIDINetworkSession sessionWithPropertyList:ThroughXML([s propertyList])];
    PASS_EQUAL(back, s, "a session survives an XML property list round trip");
    PASS(back.port == 5004 && back.enabled && back.policy == MIDINetworkConnectionPolicyDirectoryOnly,
         "port, enabled flag and policy come back");
    PASS_EQUAL([[s propertyList] objectForKey:MIDINetworkKeyPolicy], @"directory", "the policy travels as a name");
    MIDINetworkSession *copy = [[s copy] autorelease];
    PASS(copy != s && [copy isEqual:s], "copy gives an equal, distinct session");

    NSMutableDictionary *bad = [[[s propertyList] mutableCopy] autorelease];
    [bad setObject:@"everyone" forKey:MIDINetworkKeyPolicy];
    PASS([MIDINetworkSession sessionWithPropertyList:bad] == nil, "an unknown policy name is rejected");
    bad = [[[s propertyList] mutableCopy] autorelease];
    [bad setObject:@"5004" forKey:MIDINetworkKeyPort];
    PASS([MIDINetworkSession sessionWithPropertyList:bad] == nil, "a port of the wrong type is rejected");
    bad = [[[s propertyList] mutableCopy] autorelease];
    [bad removeObjectForKey:MIDINetworkKeyName];
    PASS([MIDINetworkSession sessionWithPropertyList:bad] == nil, "a missing name is rejected");
    PASS([MIDINetworkSession sessionWithPropertyList:@"x"] == nil, "a non-dictionary is rejected");
    END_SET("session")

    START_SET("policy names")
    MIDINetworkConnectionPolicy p = MIDINetworkConnectionPolicyAnyone;
    PASS(MIDINetworkConnectionPolicyFromName(@"nobody", &p) && p == MIDINetworkConnectionPolicyNobody,
         "nobody parses");
    PASS(!MIDINetworkConnectionPolicyFromName(@"Nobody", &p), "names are case sensitive");
    PASS(MIDINetworkConnectionPolicyName((MIDINetworkConnectionPolicy)7) == nil, "out of range has no name");
    END_SET("policy names")

    START_SET("host")
    MIDINetworkHost *h = [MIDINetworkHost manualHostWithName:@"Laptop" address:@"10.0.0.2" port:5008];
    PASS([h isManual], "a host added by hand is manual");
    MIDINetworkHost *hb = [MIDINetworkHost hostWithPropertyList:ThroughXML([h propertyList])];
    PASS_EQUAL(hb, h, "a host survives the round trip");
    h.source = MIDINetworkHostSourceDiscovered;
    PASS_EQUAL([[h propertyList] objectForKey:MIDINetworkKeySource], @"discovered", "the source travels as a name");
    PASS(![[MIDINetworkHost hostWithPropertyList:[h propertyList]] isManual], "discovered comes back as discovered");
    END_SET("host")

    START_SET("participant")
    MIDINetworkParticipant *pt = [[[MIDINetworkParticipant alloc] init] autorelease];
    pt.identifier = @"p1";
    pt.name = @"Rack";
    pt.address = @"10.0.0.3:5004";
    pt.latency = 3.25;
    pt.state = MIDINetworkParticipantStateConnected;
    MIDINetworkParticipant *pb = [MIDINetworkParticipant participantWithPropertyList:ThroughXML([pt propertyList])];
    PASS_EQUAL(pb, pt, "a participant survives the round trip");
    PASS([pb isConnected] && pb.latency == 3.25, "state and latency come back");
    END_SET("participant")

    START_SET("port and route")
    MIDINetworkPort *port = [MIDINetworkPort portWithIdentifier:@"20:0" name:@"Synth" canSend:NO canReceive:YES];
    PASS_EQUAL([MIDINetworkPort portWithPropertyList:ThroughXML([port propertyList])], port,
               "a port survives the round trip");
    MIDINetworkRoute *r = [MIDINetworkRoute routeForSession:@"s1" inputPort:nil outputPort:@"20:0"];
    NSDictionary *rp = [r propertyList];
    PASS([rp objectForKey:MIDINetworkKeyInputPort] == nil, "an unrouted direction is left out of the plist");
    MIDINetworkRoute *rb = [MIDINetworkRoute routeWithPropertyList:ThroughXML(rp)];
    PASS_EQUAL(rb, r, "a half-routed route survives the round trip");
    PASS(rb.inputPortIdentifier == nil, "the unrouted direction comes back as nil");
    NSDictionary *badRoute = @{ MIDINetworkKeySession: @"s1", MIDINetworkKeyInputPort: @3 };
    PASS([MIDINetworkRoute routeWithPropertyList:badRoute] == nil, "a port identifier of the wrong type is rejected");
    END_SET("port and route")

    START_SET("arrays")
    MIDINetworkPort *port = [MIDINetworkPort portWithIdentifier:@"20:0" name:@"Synth" canSend:NO canReceive:YES];
    NSArray *plists = MIDINetworkPropertyListsFromModels(@[ port ]);
    PASS([MIDINetworkModelsFromPropertyLists(plists, [MIDINetworkPort class]) count] == 1, "an array maps back");
    NSArray *mixed = @[ [port propertyList], @{ @"name": @"broken" } ];
    PASS(MIDINetworkModelsFromPropertyLists(mixed, [MIDINetworkPort class]) == nil,
         "one bad element rejects the whole array");
    PASS(MIDINetworkModelsFromPropertyLists(@"x", [MIDINetworkPort class]) == nil, "a non-array is rejected");
    END_SET("arrays")

    [arp release];
    return 0;
}
