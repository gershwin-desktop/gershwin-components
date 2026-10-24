/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_NMDPeerConnection - the per-peer session state machine, driven with a
 * fake clock and a recording delegate instead of sockets. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "NMDPeerConnection.h"
#import "NMDSessionMessage.h"
#import "NMDRTPMIDI.h"
#import "NMDLatencyEstimator.h"
#import "NMDTestHex.h"

@interface Recorder : NSObject <NMDPeerConnectionDelegate>
@property (retain) NSMutableArray *sent;      /* NMDSessionMessage or NSData */
@property (retain) NSMutableArray *ports;     /* @YES = control */
@property (retain) NSMutableArray *received;
@property NSUInteger stateChanges;
@property NSUInteger latencyUpdates;
@end

@implementation Recorder
- (id) init
{
  self = [super init];
  _sent = [NSMutableArray new];
  _ports = [NSMutableArray new];
  _received = [NSMutableArray new];
  return self;
}
- (void) dealloc
{
  [_sent release]; [_ports release]; [_received release];
  [super dealloc];
}
- (void) peer: (NMDPeerConnection *)p sendData: (NSData *)d onControlPort: (BOOL)c
{
  id m = [NMDSessionMessage isSessionPacket: d]
    ? (id)[NMDSessionMessage messageWithData: d error: NULL] : (id)d;
  [_sent addObject: m];
  [_ports addObject: [NSNumber numberWithBool: c]];
}
- (void) peerDidChangeState: (NMDPeerConnection *)p { _stateChanges++; }
- (void) peerDidUpdateLatency: (NMDPeerConnection *)p { _latencyUpdates++; }
- (void) peer: (NMDPeerConnection *)p didReceiveMIDIMessages: (NSArray *)m
{
  [_received addObjectsFromArray: m];
}
- (NMDSessionMessage *) last { return [_sent lastObject]; }
- (BOOL) lastOnControl { return [[_ports lastObject] boolValue]; }
- (void) clear { [_sent removeAllObjects]; [_ports removeAllObjects]; }
@end

static NSString * const kRemote = @"remote-session";

static NMDSessionMessage *Msg(NMDSessionCommand c, uint32_t token, uint32_t ssrc)
{
  return [NMDSessionMessage messageWithCommand: c token: token ssrc: ssrc
                                         name: kRemote];
}

static NMDSessionMessage *CK(uint32_t ssrc, uint8_t n, uint64_t a, uint64_t b,
  uint64_t c)
{
  return [NMDSessionMessage clockSyncWithSSRC: ssrc count: n timestamp1: a
                                  timestamp2: b timestamp3: c];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("state table")
    NSUInteger undecided = 0, s, e;
    for (s = 0; s < NMDPeerStateCount; s++)
      for (e = 0; e < NMDPeerEventCount; e++)
        {
          NMDPeerRuleKind k = NMDPeerRuleKindFor(s, e);
          if (k == NMDPeerRuleUndecided)
            {
              NSLog(@"undecided: %@ x %@", NMDPeerStateName(s), NMDPeerEventName(e));
              undecided++;
            }
          if (k == NMDPeerRuleIgnore && NMDPeerRuleReasonFor(s, e) == nil)
            undecided++;
        }
    PASS(undecided == 0, "every state x event pair is a transition or a "
      "reasoned ignore");
    for (e = 0; e < NMDPeerEventCount; e++)
      if (NMDPeerRuleKindFor(NMDPeerStateClosed, e) != NMDPeerRuleIgnore) undecided++;
    PASS(undecided == 0, "closed is final");
  END_SET("state table")

  START_SET("initiator")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 0x1111 localName: @"local"
        clockEpoch: 100.0] autorelease];
    uint32_t tok;
    p.delegate = r;

    [p inviteAt: 100.0];
    PASS(p.state == NMDPeerStateInvitingControl, "invite -> inviting-control");
    PASS([r last].command == NMDSessionCommandInvitation && [r lastOnControl]
      && [[r last].name isEqual: @"local"] && [r last].ssrc == 0x1111,
      "IN with our name and SSRC goes to the control port");
    tok = [r last].token;
    PASS(p.nextDeadline == 101.5, "invitation retry scheduled 1.5 s later");

    [p fireTimersAt: 101.5];
    PASS([r.sent count] == 2 && [r last].token == tok && [r lastOnControl],
      "the invitation is retried with the same token");

    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok + 1, 0x2222)
              onControlPort: YES at: 101.2];
    PASS(p.state == NMDPeerStateInvitingControl, "OK with a foreign token is "
      "not ours (owner filters by token)") ;
    PASS(![p ownsSessionMessage: Msg(NMDSessionCommandAccept, tok + 1, 0x2222)],
      "and ownsSessionMessage says so");

    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok, 0x2222)
              onControlPort: YES at: 101.3];
    PASS(p.state == NMDPeerStateInvitingData, "OK on control -> inviting-data");
    PASS([r last].command == NMDSessionCommandInvitation && ![r lastOnControl],
      "IN goes to the data port next");
    PASS(p.remoteSSRC == 0x2222 && [p.remoteName isEqual: kRemote],
      "the peer's SSRC and name are learned from OK");

    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok, 0x2222)
              onControlPort: NO at: 101.4];
    PASS(p.state == NMDPeerStateSynchronising, "OK on data -> synchronising");
    PASS([r last].command == NMDSessionCommandClockSync && [r last].count == 0
      && ![r lastOnControl], "CK0 goes to the data port");
    PASS([r last].timestamp1 == 14000, "timestamp1 is 10 kHz ticks since the epoch");

    [r clear];
    [p handleSessionMessage: CK(0x2222, 1, 14000, 777, 0) onControlPort: NO
                         at: 101.42];
    PASS(p.state == NMDPeerStateConnected, "CK1 -> connected");
    PASS([r last].count == 2 && [r last].timestamp1 == 14000
      && [r last].timestamp2 == 777 && [r last].timestamp3 == 14200,
      "CK2 echoes timestamps 1 and 2 and adds ours");
    PASS(EQ(p.latency, 0.01), "latency is half the round trip: 10 ms");
    PASS(r.latencyUpdates == 1, "the delegate hears about the new latency");

    PASS(EQ(p.nextDeadline, 101.42 + 1.5), "next sync in the fast phase");
    [r clear];
    [p fireTimersAt: 102.92];
    PASS([r last].command == NMDSessionCommandClockSync && [r last].count == 0,
      "periodic CK0");
    [p handleSessionMessage: CK(0x2222, 1, 12345, 1, 0) onControlPort: NO
                         at: 103.0];
    PASS([r.sent count] == 1 && p.state == NMDPeerStateConnected,
      "a CK1 for a different CK0 is not answered");

    /* MIDI in and out */
    [r clear];
    PASS([p sendMIDIMessages: @[NMDHex("903c64")] at: 103.0], "send while connected");
    PASS([r.sent count] == 1 && ![r lastOnControl]
      && ((const uint8_t *)[[r.sent lastObject] bytes])[1] == 0x61,
      "MIDI goes out as RTP on the data port");
    [p handleRTPPacket: NMDHex("80610001 00000000 00002222 03 b0077f") at: 103.1];
    PASS([r.received count] == 1
      && [[r.received objectAtIndex: 0] isEqual: NMDHex("b0077f")],
      "incoming RTP MIDI is delivered");
    PASS(EQ(p.nextDeadline, 104.1), "receiver feedback scheduled");
    [r clear];
    [p fireTimersAt: 104.1];
    {
      BOOL sawRS = NO;
      NSUInteger i;
      for (i = 0; i < [r.sent count]; i++)
        {
          id m = [r.sent objectAtIndex: i];
          if ([m isKindOfClass: [NMDSessionMessage class]]
            && [(NMDSessionMessage *)m command] == NMDSessionCommandFeedback
            && [(NMDSessionMessage *)m feedbackSequence] == 1
            && [[r.ports objectAtIndex: i] boolValue])
            sawRS = YES;
        }
      PASS(sawRS, "RS with the last sequence number goes to the control port");
    }

    [r clear];
    [p closeAt: 105.0];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonLocal,
      "close -> closed");
    PASS([r.sent count] == 2
      && [[r.sent objectAtIndex: 0] command] == NMDSessionCommandEnd
      && [[r.sent objectAtIndex: 1] command] == NMDSessionCommandEnd
      && [[r.ports objectAtIndex: 0] boolValue]
      && ![[r.ports objectAtIndex: 1] boolValue]
      && [[r.sent objectAtIndex: 0] token] == tok,
      "BY with our token on both the control and the data port");
    PASS(p.nextDeadline == 0, "no timers after close");
    PASS(![p sendMIDIMessages: @[NMDHex("903c64")] at: 105.0],
      "nothing is sent after close");
  END_SET("initiator")

  START_SET("invitation retries with the default timing")
    /* A peer on WLAN may sleep for many seconds; common practice is to
     * keep inviting every 1.5 s for about 30 s. */
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    NSUInteger i, sent = 0;
    p.delegate = r;
    [p inviteAt: 0];
    PASS(EQ(p.nextDeadline, 1.5), "the first retry follows 1.5 s later");
    for (i = 1; i < 20; i++) [p fireTimersAt: 1.5 * i];
    for (id m in r.sent) if ([m command] == NMDSessionCommandInvitation) sent++;
    PASS(sent == 20 && p.state == NMDPeerStateInvitingControl,
      "20 invitations on the control port, still inviting after 28.5 s");
    [p fireTimersAt: 30.0];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonTimeout,
      "given up after 30 s without an answer");
  END_SET("invitation retries with the default timing")

  START_SET("late OK for an earlier attempt")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    uint32_t tok;
    NSUInteger i;
    p.delegate = r;
    [p inviteAt: 0];
    tok = p.token;
    for (i = 1; i <= 4; i++) [p fireTimersAt: 1.5 * i];
    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok, 0x77)
              onControlPort: YES at: 6.2];
    PASS(p.state == NMDPeerStateInvitingData && ![r lastOnControl],
      "an OK that answers the first of five invitations is accepted");
    [r clear];
    [p fireTimersAt: 7.7];
    PASS([r last].command == NMDSessionCommandInvitation && ![r lastOnControl]
      && [r last].token == tok, "the data port is retried the same way");
    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok, 0x77)
              onControlPort: YES at: 7.8];
    PASS(p.state == NMDPeerStateInvitingData,
      "a second late OK for the control port changes nothing");
    [p handleSessionMessage: Msg(NMDSessionCommandAccept, tok, 0x77)
              onControlPort: NO at: 8.0];
    PASS(p.state == NMDPeerStateSynchronising, "the late data OK is accepted too");
  END_SET("late OK for an earlier attempt")

  START_SET("clock sync schedule")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    NSMutableArray *gaps = [NSMutableArray array];
    NSTimeInterval t = 1.0, last = 0;
    NSUInteger i;
    p.delegate = r;
    [p inviteAt: 0];
    [p handleSessionMessage: Msg(NMDSessionCommandAccept, p.token, 9)
              onControlPort: YES at: 0.1];
    [p handleSessionMessage: Msg(NMDSessionCommandAccept, p.token, 9)
              onControlPort: NO at: 0.2];
    for (i = 0; i < 9; i++)
      {
        NMDSessionMessage *ck = [r last];
        if (i > 0) { t = p.nextDeadline; [p fireTimersAt: t]; ck = [r last]; }
        else t = 0.2;
        if (i > 0) [gaps addObject: [NSNumber numberWithDouble: t - last]];
        last = t;
        [p handleSessionMessage: CK(9, 1, ck.timestamp1, 5, 0) onControlPort: NO
                             at: t + 0.001];
      }
    {
      BOOL fast = YES, slow = YES;
      for (i = 0; i < 5; i++) fast = fast && EQ([[gaps objectAtIndex: i] doubleValue], 1.501);
      for (i = 5; i < 8; i++) slow = slow && EQ([[gaps objectAtIndex: i] doubleValue], 10.001);
      PASS(fast, "the first six syncs come 1.5 s apart");
      PASS(slow, "then every 10 s");
    }
  END_SET("clock sync schedule")

  START_SET("latency spike")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleResponder localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 7, 8) onControlPort: YES at: 0];
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 7, 8) onControlPort: NO at: 0];
    /* round trips of 980 ms, then 2.4, 4.6 and 3 ms (10 kHz ticks) */
    [p handleSessionMessage: CK(8, 2, 100, 0, 9900) onControlPort: NO at: 1];
    PASS(EQ(p.latency, 0.490), "one measurement: shown as it is");
    [p handleSessionMessage: CK(8, 2, 200, 0, 224) onControlPort: NO at: 2];
    [p handleSessionMessage: CK(8, 2, 300, 0, 346) onControlPort: NO at: 3];
    PASS(EQ(p.latency, 0.0023), "the 490 ms spike no longer shows once three syncs are in");
    PASS(EQ(p.lastLatencySample, 0.0023), "the raw last value stays available");
  END_SET("latency spike")

  START_SET("initiator gives up")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    NSUInteger i;
    p.delegate = r;
    p.invitationAttempts = 3;
    p.invitationRetryInterval = 1;
    [p inviteAt: 0];
    for (i = 1; i <= 3; i++) [p fireTimersAt: (double)i];
    PASS([r.sent count] == 3, "three invitations in all");
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonTimeout,
      "no answer -> closed by timeout");
  END_SET("initiator gives up")

  START_SET("rejected")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    [p inviteAt: 0];
    [p handleSessionMessage: Msg(NMDSessionCommandReject, p.token, 9)
              onControlPort: YES at: 0.1];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonRejected,
      "NO -> closed, rejected");
  END_SET("rejected")

  START_SET("responder")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleResponder localSSRC: 0x3333 localName: @"local"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    p.idleProbeInterval = 30;
    p.clockSyncTimeout = 2;
    p.clockSyncAttempts = 3;

    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: YES at: 10];
    PASS(p.state == NMDPeerStateAccepted, "IN on control -> accepted");
    PASS([r last].command == NMDSessionCommandAccept && [r lastOnControl]
      && [r last].token == 0xABCD && [r last].ssrc == 0x3333,
      "OK echoes the token, with our SSRC, on the control port");
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: YES at: 10.5];
    PASS([r.sent count] == 2 && p.state == NMDPeerStateAccepted,
      "a retried IN is answered again");
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: NO at: 11];
    PASS(p.state == NMDPeerStateSynchronising && ![r lastOnControl]
      && [r last].command == NMDSessionCommandAccept,
      "IN on data -> synchronising, OK on the data port");
    [p handleSessionMessage: CK(0x4444, 0, 500, 0, 0) onControlPort: NO at: 11.1];
    PASS([r last].count == 1 && [r last].timestamp1 == 500
      && [r last].timestamp2 == 111000, "CK0 is answered with CK1");
    PASS(p.state == NMDPeerStateSynchronising, "still synchronising after CK0");
    [p handleSessionMessage: CK(0x4444, 2, 500, 111000, 540) onControlPort: NO
                         at: 11.2];
    PASS(p.state == NMDPeerStateConnected, "CK2 -> connected");
    PASS(EQ(p.latency, 0.002), "latency from the initiator's stamps: 2 ms");
    [p handleSessionMessage: CK(0x4444, 2, 600, 111500, 600) onControlPort: NO
                         at: 11.2];
    PASS(p.latency == 0.0, "a round trip below one tick is a latency of 0");

    /* the peer goes silent: probe, then give up */
    PASS(EQ(p.nextDeadline, 41.2), "idle probe 30 s after the last packet");
    [r clear];
    [p fireTimersAt: 41.2];
    PASS([r last].command == NMDSessionCommandClockSync && [r last].count == 0,
      "a quiet initiator is probed with CK0");
    [p fireTimersAt: 43.2];
    [p fireTimersAt: 45.2];
    PASS(p.state == NMDPeerStateConnected, "still waiting after two misses");
    [p fireTimersAt: 47.2];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonTimeout,
      "three unanswered probes: the peer is gone");
  END_SET("responder")

  START_SET("responder: peer ends")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleResponder localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 7, 8)
              onControlPort: YES at: 0];
    PASS([p ownsSessionMessage: Msg(NMDSessionCommandEnd, 0, 8)],
      "BY is matched by SSRC as well as by token");
    [p handleSessionMessage: Msg(NMDSessionCommandEnd, 7, 8) onControlPort: YES
                         at: 1];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonRemote,
      "BY -> closed by the remote");
    PASS(r.stateChanges == 2, "the delegate saw both state changes");
  END_SET("responder: peer ends")

  START_SET("responder: data IN never comes")
    Recorder *r = [[Recorder new] autorelease];
    NMDPeerConnection *p = [[[NMDPeerConnection alloc]
      initWithRole: NMDPeerRoleResponder localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    p.invitationAttempts = 2;
    p.invitationRetryInterval = 1;
    [p handleSessionMessage: Msg(NMDSessionCommandInvitation, 7, 8)
              onControlPort: YES at: 0];
    [p fireTimersAt: 2];
    PASS(p.state == NMDPeerStateClosed && p.closeReason == NMDPeerCloseReasonTimeout,
      "half-open session times out");
  END_SET("responder: data IN never comes")

  [arp release];
  return 0;
}
