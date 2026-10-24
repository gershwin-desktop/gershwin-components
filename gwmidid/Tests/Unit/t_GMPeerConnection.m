/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_GMPeerConnection - the per-peer session state machine, driven with a
 * fake clock and a recording delegate instead of sockets. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GMPeerConnection.h"
#import "GMSessionMessage.h"
#import "GMRTPMIDI.h"
#import "GMTestHex.h"

@interface Recorder : NSObject <GMPeerConnectionDelegate>
@property (retain) NSMutableArray *sent;      /* GMSessionMessage or NSData */
@property (retain) NSMutableArray *ports;     /* @YES = control */
@property (retain) NSMutableArray *received;
@property NSUInteger stateChanges;
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
- (void) peer: (GMPeerConnection *)p sendData: (NSData *)d onControlPort: (BOOL)c
{
  id m = [GMSessionMessage isSessionPacket: d]
    ? (id)[GMSessionMessage messageWithData: d error: NULL] : (id)d;
  [_sent addObject: m];
  [_ports addObject: [NSNumber numberWithBool: c]];
}
- (void) peerDidChangeState: (GMPeerConnection *)p { _stateChanges++; }
- (void) peer: (GMPeerConnection *)p didReceiveMIDIMessages: (NSArray *)m
{
  [_received addObjectsFromArray: m];
}
- (GMSessionMessage *) last { return [_sent lastObject]; }
- (BOOL) lastOnControl { return [[_ports lastObject] boolValue]; }
- (void) clear { [_sent removeAllObjects]; [_ports removeAllObjects]; }
@end

static NSString * const kRemote = @"remote-session";

static GMSessionMessage *Msg(GMSessionCommand c, uint32_t token, uint32_t ssrc)
{
  return [GMSessionMessage messageWithCommand: c token: token ssrc: ssrc
                                         name: kRemote];
}

static GMSessionMessage *CK(uint32_t ssrc, uint8_t n, uint64_t a, uint64_t b,
  uint64_t c)
{
  return [GMSessionMessage clockSyncWithSSRC: ssrc count: n timestamp1: a
                                  timestamp2: b timestamp3: c];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("state table")
    NSUInteger undecided = 0, s, e;
    for (s = 0; s < GMPeerStateCount; s++)
      for (e = 0; e < GMPeerEventCount; e++)
        {
          GMPeerRuleKind k = GMPeerRuleKindFor(s, e);
          if (k == GMPeerRuleUndecided)
            {
              NSLog(@"undecided: %@ x %@", GMPeerStateName(s), GMPeerEventName(e));
              undecided++;
            }
          if (k == GMPeerRuleIgnore && GMPeerRuleReasonFor(s, e) == nil)
            undecided++;
        }
    PASS(undecided == 0, "every state x event pair is a transition or a "
      "reasoned ignore");
    for (e = 0; e < GMPeerEventCount; e++)
      if (GMPeerRuleKindFor(GMPeerStateClosed, e) != GMPeerRuleIgnore) undecided++;
    PASS(undecided == 0, "closed is final");
  END_SET("state table")

  START_SET("initiator")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleInitiator localSSRC: 0x1111 localName: @"local"
        clockEpoch: 100.0] autorelease];
    uint32_t tok;
    p.delegate = r;

    [p inviteAt: 100.0];
    PASS(p.state == GMPeerStateInvitingControl, "invite -> inviting-control");
    PASS([r last].command == GMSessionCommandInvitation && [r lastOnControl]
      && [[r last].name isEqual: @"local"] && [r last].ssrc == 0x1111,
      "IN with our name and SSRC goes to the control port");
    tok = [r last].token;
    PASS(p.nextDeadline == 101.0, "invitation retry scheduled a second later");

    [p fireTimersAt: 101.0];
    PASS([r.sent count] == 2 && [r last].token == tok && [r lastOnControl],
      "the invitation is retried with the same token");

    [p handleSessionMessage: Msg(GMSessionCommandAccept, tok + 1, 0x2222)
              onControlPort: YES at: 101.2];
    PASS(p.state == GMPeerStateInvitingControl, "OK with a foreign token is "
      "not ours (owner filters by token)") ;
    PASS(![p ownsSessionMessage: Msg(GMSessionCommandAccept, tok + 1, 0x2222)],
      "and ownsSessionMessage says so");

    [p handleSessionMessage: Msg(GMSessionCommandAccept, tok, 0x2222)
              onControlPort: YES at: 101.3];
    PASS(p.state == GMPeerStateInvitingData, "OK on control -> inviting-data");
    PASS([r last].command == GMSessionCommandInvitation && ![r lastOnControl],
      "IN goes to the data port next");
    PASS(p.remoteSSRC == 0x2222 && [p.remoteName isEqual: kRemote],
      "the peer's SSRC and name are learned from OK");

    [p handleSessionMessage: Msg(GMSessionCommandAccept, tok, 0x2222)
              onControlPort: NO at: 101.4];
    PASS(p.state == GMPeerStateSynchronising, "OK on data -> synchronising");
    PASS([r last].command == GMSessionCommandClockSync && [r last].count == 0
      && ![r lastOnControl], "CK0 goes to the data port");
    PASS([r last].timestamp1 == 14000, "timestamp1 is 10 kHz ticks since the epoch");

    [r clear];
    [p handleSessionMessage: CK(0x2222, 1, 14000, 777, 0) onControlPort: NO
                         at: 101.42];
    PASS(p.state == GMPeerStateConnected, "CK1 -> connected");
    PASS([r last].count == 2 && [r last].timestamp1 == 14000
      && [r last].timestamp2 == 777 && [r last].timestamp3 == 14200,
      "CK2 echoes timestamps 1 and 2 and adds ours");
    PASS(EQ(p.latency, 0.01), "latency is half the round trip: 10 ms");

    PASS(EQ(p.nextDeadline, 101.42 + 1.5), "next sync in the fast phase");
    [r clear];
    [p fireTimersAt: 102.92];
    PASS([r last].command == GMSessionCommandClockSync && [r last].count == 0,
      "periodic CK0");
    [p handleSessionMessage: CK(0x2222, 1, 12345, 1, 0) onControlPort: NO
                         at: 103.0];
    PASS([r.sent count] == 1 && p.state == GMPeerStateConnected,
      "a CK1 for a different CK0 is not answered");

    /* MIDI in and out */
    [r clear];
    PASS([p sendMIDIMessages: @[GMHex("903c64")] at: 103.0], "send while connected");
    PASS([r.sent count] == 1 && ![r lastOnControl]
      && ((const uint8_t *)[[r.sent lastObject] bytes])[1] == 0x61,
      "MIDI goes out as RTP on the data port");
    [p handleRTPPacket: GMHex("80610001 00000000 00002222 03 b0077f") at: 103.1];
    PASS([r.received count] == 1
      && [[r.received objectAtIndex: 0] isEqual: GMHex("b0077f")],
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
          if ([m isKindOfClass: [GMSessionMessage class]]
            && [(GMSessionMessage *)m command] == GMSessionCommandFeedback
            && [(GMSessionMessage *)m feedbackSequence] == 1
            && [[r.ports objectAtIndex: i] boolValue])
            sawRS = YES;
        }
      PASS(sawRS, "RS with the last sequence number goes to the control port");
    }

    [r clear];
    [p closeAt: 105.0];
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonLocal,
      "close -> closed");
    PASS([r.sent count] == 2
      && [[r.sent objectAtIndex: 0] command] == GMSessionCommandEnd
      && [[r.sent objectAtIndex: 1] command] == GMSessionCommandEnd
      && [[r.ports objectAtIndex: 0] boolValue]
      && ![[r.ports objectAtIndex: 1] boolValue]
      && [[r.sent objectAtIndex: 0] token] == tok,
      "BY with our token on both the control and the data port");
    PASS(p.nextDeadline == 0, "no timers after close");
    PASS(![p sendMIDIMessages: @[GMHex("903c64")] at: 105.0],
      "nothing is sent after close");
  END_SET("initiator")

  START_SET("initiator gives up")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    NSUInteger i;
    p.delegate = r;
    p.invitationAttempts = 3;
    [p inviteAt: 0];
    for (i = 1; i <= 3; i++) [p fireTimersAt: (double)i];
    PASS([r.sent count] == 3, "three invitations in all");
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonTimeout,
      "no answer -> closed by timeout");
  END_SET("initiator gives up")

  START_SET("rejected")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleInitiator localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    [p inviteAt: 0];
    [p handleSessionMessage: Msg(GMSessionCommandReject, p.token, 9)
              onControlPort: YES at: 0.1];
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonRejected,
      "NO -> closed, rejected");
  END_SET("rejected")

  START_SET("responder")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleResponder localSSRC: 0x3333 localName: @"local"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    p.idleProbeInterval = 30;
    p.clockSyncTimeout = 2;
    p.clockSyncAttempts = 3;

    [p handleSessionMessage: Msg(GMSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: YES at: 10];
    PASS(p.state == GMPeerStateAccepted, "IN on control -> accepted");
    PASS([r last].command == GMSessionCommandAccept && [r lastOnControl]
      && [r last].token == 0xABCD && [r last].ssrc == 0x3333,
      "OK echoes the token, with our SSRC, on the control port");
    [p handleSessionMessage: Msg(GMSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: YES at: 10.5];
    PASS([r.sent count] == 2 && p.state == GMPeerStateAccepted,
      "a retried IN is answered again");
    [p handleSessionMessage: Msg(GMSessionCommandInvitation, 0xABCD, 0x4444)
              onControlPort: NO at: 11];
    PASS(p.state == GMPeerStateSynchronising && ![r lastOnControl]
      && [r last].command == GMSessionCommandAccept,
      "IN on data -> synchronising, OK on the data port");
    [p handleSessionMessage: CK(0x4444, 0, 500, 0, 0) onControlPort: NO at: 11.1];
    PASS([r last].count == 1 && [r last].timestamp1 == 500
      && [r last].timestamp2 == 111000, "CK0 is answered with CK1");
    PASS(p.state == GMPeerStateSynchronising, "still synchronising after CK0");
    [p handleSessionMessage: CK(0x4444, 2, 500, 111000, 540) onControlPort: NO
                         at: 11.2];
    PASS(p.state == GMPeerStateConnected, "CK2 -> connected");
    PASS(EQ(p.latency, 0.002), "latency from the initiator's stamps: 2 ms");

    /* the peer goes silent: probe, then give up */
    PASS(EQ(p.nextDeadline, 41.2), "idle probe 30 s after the last packet");
    [r clear];
    [p fireTimersAt: 41.2];
    PASS([r last].command == GMSessionCommandClockSync && [r last].count == 0,
      "a quiet initiator is probed with CK0");
    [p fireTimersAt: 43.2];
    [p fireTimersAt: 45.2];
    PASS(p.state == GMPeerStateConnected, "still waiting after two misses");
    [p fireTimersAt: 47.2];
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonTimeout,
      "three unanswered probes: the peer is gone");
  END_SET("responder")

  START_SET("responder: peer ends")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleResponder localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    [p handleSessionMessage: Msg(GMSessionCommandInvitation, 7, 8)
              onControlPort: YES at: 0];
    PASS([p ownsSessionMessage: Msg(GMSessionCommandEnd, 0, 8)],
      "BY is matched by SSRC as well as by token");
    [p handleSessionMessage: Msg(GMSessionCommandEnd, 7, 8) onControlPort: YES
                         at: 1];
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonRemote,
      "BY -> closed by the remote");
    PASS(r.stateChanges == 2, "the delegate saw both state changes");
  END_SET("responder: peer ends")

  START_SET("responder: data IN never comes")
    Recorder *r = [[Recorder new] autorelease];
    GMPeerConnection *p = [[[GMPeerConnection alloc]
      initWithRole: GMPeerRoleResponder localSSRC: 1 localName: @"l"
        clockEpoch: 0] autorelease];
    p.delegate = r;
    p.invitationAttempts = 2;
    p.invitationRetryInterval = 1;
    [p handleSessionMessage: Msg(GMSessionCommandInvitation, 7, 8)
              onControlPort: YES at: 0];
    [p fireTimersAt: 2];
    PASS(p.state == GMPeerStateClosed && p.closeReason == GMPeerCloseReasonTimeout,
      "half-open session times out");
  END_SET("responder: data IN never comes")

  [arp release];
  return 0;
}
