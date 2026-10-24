/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_NMDLocalSession - two local sessions wired back to back through an
 * in-memory network: invitation, clock sync, MIDI both ways, policies,
 * clean shutdown and a peer that vanishes. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "NMDLocalSession.h"
#import "NMDSocketAddress.h"
#import "NMDSessionMessage.h"
#import "NMDTestHex.h"

@class Net;

/* One endpoint of the fake network: a session plus its own address. */
@interface Node : NSObject <NMDSessionTransport, NMDLocalSessionDelegate>
@property (retain) NMDLocalSession *session;
@property (retain) NSData *address;     /* control port address */
@property (assign) Net *net;
@property (retain) NSMutableArray *midi;
@property BOOL allowDirectory;
@property NSUInteger changes;
@property NMDPeerCloseReason lastCloseReason;
@end

@interface Net : NSObject
@property (retain) NSMutableArray *queue;  /* @[data, from, to, @(control)] */
@property (retain) NSMutableArray *nodes;
@property BOOL dropAll;
@property NSUInteger delivered;
- (void) runAt: (NSTimeInterval)now;
@end

@implementation Node
- (id) init { self = [super init]; _midi = [NSMutableArray new]; return self; }
- (void) dealloc { [_session release]; [_address release]; [_midi release]; [super dealloc]; }
- (void) sendData: (NSData *)d to: (NSData *)to control: (BOOL)c
{
  NSData *from = c ? _address
    : NMDAddressWithPort(_address, NMDAddressPort(_address) + 1);
  if (!_net.dropAll)
    [_net.queue addObject: @[d, from, to, [NSNumber numberWithBool: c]]];
}
- (BOOL) session: (NMDLocalSession *)s directoryAllowsAddress: (NSData *)a
            name: (NSString *)n
{
  return _allowDirectory;
}
- (void) session: (NMDLocalSession *)s didReceiveMIDIMessages: (NSArray *)m
        fromPeer: (NMDPeerConnection *)p
{
  [_midi addObjectsFromArray: m];
}
- (void) sessionParticipantsDidChange: (NMDLocalSession *)s { _changes++; }
- (void) sessionParticipantLatencyDidChange: (NMDLocalSession *)s { }
- (void) session: (NMDLocalSession *)s peerDidClose: (NMDPeerConnection *)p
{
  _lastCloseReason = p.closeReason;
}
@end

@implementation Net
- (id) init
{
  self = [super init];
  _queue = [NSMutableArray new];
  _nodes = [NSMutableArray new];
  return self;
}
- (void) dealloc { [_queue release]; [_nodes release]; [super dealloc]; }
- (void) runAt: (NSTimeInterval)now
{
  while ([_queue count] > 0)
    {
      NSArray *pk = [[[_queue objectAtIndex: 0] retain] autorelease];
      NSData *to = [pk objectAtIndex: 2];
      [_queue removeObjectAtIndex: 0];
      for (Node *n in _nodes)
        {
          if (NMDAddressHostsEqual(n.address, to)
            && (NMDAddressPort(to) == NMDAddressPort(n.address)
              || NMDAddressPort(to) == NMDAddressPort(n.address) + 1))
            {
              _delivered++;
              [n.session receiveDatagram: [pk objectAtIndex: 0]
                                    from: [pk objectAtIndex: 1]
                               onControl: [[pk objectAtIndex: 3] boolValue]
                                      at: now];
            }
        }
    }
}
@end

static Node *MakeNode(Net *net, NSString *name, NSString *host, uint16_t port,
  uint32_t ssrc)
{
  Node *n = [[Node new] autorelease];
  NMDLocalSession *s = [[[NMDLocalSession alloc] initWithName: name port: port
    ssrc: ssrc clockEpoch: 0] autorelease];
  n.session = s;
  n.address = NMDAddressFromNumericHost(host, port);
  n.net = net;
  s.transport = n;
  s.delegate = n;
  [net.nodes addObject: n];
  return n;
}

static NMDPeerConnection *OnlyPeer(Node *n)
{
  NSArray *p = n.session.peers;
  return [p count] == 1 ? [p objectAtIndex: 0] : nil;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  PASS(NMDAddressPort(NMDAddressFromNumericHost(@"192.0.2.1", 5004)) == 5004
    && [NMDAddressHost(NMDAddressFromNumericHost(@"192.0.2.1", 5004))
      isEqual: @"192.0.2.1"], "IPv4 address helpers");
  PASS([NMDAddressDescription(NMDAddressFromNumericHost(@"2001:db8::1", 5004))
    isEqual: @"[2001:db8::1]:5004"], "IPv6 address helpers");
  PASS(NMDAddressFromNumericHost(@"host.local", 5004) == nil,
    "names are not resolved here");

  START_SET("connect, MIDI both ways, clean close")
    Net *net = [[Net new] autorelease];
    Node *a = MakeNode(net, @"Alpha", @"192.0.2.1", 5004, 0xA);
    Node *b = MakeNode(net, @"Beta", @"192.0.2.2", 5006, 0xB);
    NMDPeerConnection *pa, *pb;
    NSTimeInterval t = 1.0;

    [a.session inviteAddress: b.address at: t];
    [net runAt: t];
    pa = OnlyPeer(a);
    pb = OnlyPeer(b);
    PASS(pa != nil && pb != nil, "each side has one participant");
    PASS(pa.role == NMDPeerRoleInitiator && pb.role == NMDPeerRoleResponder,
      "roles");
    PASS(pa.state == NMDPeerStateConnected && pb.state == NMDPeerStateConnected,
      "IN/OK on both ports and CK0/1/2 bring both sides up");
    PASS([pa.remoteName isEqual: @"Beta"] && [pb.remoteName isEqual: @"Alpha"],
      "names exchanged");
    PASS(pa.latency >= 0 && pb.latency >= 0, "both sides learned a latency");
    PASS(NMDAddressPort(pb.dataAddress) == 5005,
      "the responder learned the data address from the data IN");

    [a.session sendMIDIMessages: @[NMDHex("903c64"), NMDHex("e00040")] at: t];
    [net runAt: t];
    PASS([b.midi count] == 2 && [[b.midi objectAtIndex: 1] isEqual: NMDHex("e00040")],
      "initiator to responder");
    {
      NSMutableData *sx = [NSMutableData dataWithBytes: "\xF0" length: 1];
      int i;
      for (i = 0; i < 3000; i++) { uint8_t v = i & 0x7F; [sx appendBytes: &v length: 1]; }
      [sx appendBytes: "\xF7" length: 1];
      [b.session sendMIDIMessages: @[NMDHex("b0017f"), sx] at: t];
      [net runAt: t];
      PASS([a.midi count] == 2 && [[a.midi objectAtIndex: 1] isEqual: sx],
        "responder to initiator, including a 3002-byte sysex");
    }

    /* timers: the periodic sync keeps both sides up */
    for (t = 1.5; t < 40.0; t += 0.5)
      {
        [a.session fireTimersAt: t];
        [b.session fireTimersAt: t];
        [net runAt: t];
      }
    PASS(OnlyPeer(a).state == NMDPeerStateConnected
      && OnlyPeer(b).state == NMDPeerStateConnected,
      "40 s of timers: still connected");

    [a.session closeAllAt: t];
    [net runAt: t];
    PASS([a.session.peers count] == 0 && [b.session.peers count] == 0,
      "BY removes the participant on both sides");
  END_SET("connect, MIDI both ways, clean close")

  START_SET("policies")
    Net *net = [[Net new] autorelease];
    Node *a = MakeNode(net, @"Alpha", @"192.0.2.1", 5004, 0xA);
    Node *b = MakeNode(net, @"Beta", @"192.0.2.2", 5006, 0xB);

    b.session.policy = NMDConnectionPolicyNobody;
    [a.session inviteAddress: b.address at: 1];
    [net runAt: 1];
    PASS([a.session.peers count] == 0 && [b.session.peers count] == 0,
      "policy nobody: NO, and the inviter drops the attempt");
    PASS(a.lastCloseReason == NMDPeerCloseReasonRejected,
      "the inviter is told that it was rejected");

    b.session.policy = NMDConnectionPolicyDirectory;
    b.allowDirectory = NO;
    [a.session inviteAddress: b.address at: 2];
    [net runAt: 2];
    PASS([b.session.peers count] == 0, "directory policy, host not listed: refused");

    b.allowDirectory = YES;
    [a.session inviteAddress: b.address at: 3];
    [net runAt: 3];
    PASS(OnlyPeer(b).state == NMDPeerStateConnected,
      "directory policy, host listed: accepted");

    {
      Node *c = MakeNode(net, @"Gamma", @"192.0.2.3", 5008, 0xC);
      [c.session inviteAddress: a.address at: 4];
      [net runAt: 4];
      PASS(OnlyPeer(c).state == NMDPeerStateConnected
        && [a.session.peers count] == 2,
        "a session takes several participants at once");
      [a.session sendMIDIMessages: @[NMDHex("903c64")] at: 4];
      [net runAt: 4];
      PASS([b.midi count] == 1 && [c.midi count] == 1,
        "outgoing MIDI goes to every participant");
    }
    PASS(NMDConnectionPolicyFromString(@"directory", NULL)
      == NMDConnectionPolicyDirectory, "policy names");
    {
      BOOL ok = YES;
      NMDConnectionPolicyFromString(@"everyone", &ok);
      PASS(!ok, "an unknown policy name is reported, not guessed");
    }
  END_SET("policies")

  START_SET("vanished peer")
    Net *net = [[Net new] autorelease];
    Node *a = MakeNode(net, @"Alpha", @"192.0.2.1", 5004, 0xA);
    Node *b = MakeNode(net, @"Beta", @"192.0.2.2", 5006, 0xB);
    NSTimeInterval t;

    [b.session inviteAddress: a.address at: 1];
    [net runAt: 1];
    PASS(OnlyPeer(a).state == NMDPeerStateConnected, "connected");
    [net.nodes removeObject: b];   /* b's host loses power */
    for (t = 1.5; t < 60.0 && [a.session.peers count] > 0; t += 0.5)
      {
        [a.session fireTimersAt: t];
        [net runAt: t];
      }
    PASS([a.session.peers count] == 0, "the responder notices and drops it");
    PASS(t > 30.0 && t < 40.0, "after the idle probe and its retries (%.1f s)", t);
  END_SET("vanished peer")

  [arp release];
  return 0;
}
