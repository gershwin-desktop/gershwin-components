/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMPeerConnection.h"
#import "GMSessionMessage.h"
#import "GMRTPMIDI.h"
#include <stdlib.h>
#include <math.h>

typedef NS_ENUM(NSInteger, GMPeerAction) {
  GMPeerActionNone = 0,
  GMPeerActionSendControlInvitation,
  GMPeerActionAcceptControl,
  GMPeerActionResendControlAccept,
  GMPeerActionAcceptData,
  GMPeerActionResendDataAccept,
  GMPeerActionSendDataInvitation,
  GMPeerActionStartClockSync,
  GMPeerActionRejected,
  GMPeerActionRemoteEnded,
  GMPeerActionAnswerClockSync,
  GMPeerActionFinishClockSync,
  GMPeerActionLearnLatency,
  GMPeerActionDeliverMIDI,
  GMPeerActionTimers,
  GMPeerActionLocalClose
};

typedef struct {
  GMPeerRuleKind kind;
  GMPeerState target;
  GMPeerAction action;
  const char *reason;
} GMPeerRule;

/* The whole protocol as a state x event table.  t_GMPeerConnection checks
 * that no pair is left undecided, so a new state or event cannot be added
 * without deciding what each of its pairs does. */
#define T(s, e, t, a) [GMPeerState##s][GMPeerEvent##e] = \
  { GMPeerRuleTransition, GMPeerState##t, GMPeerAction##a, NULL }
#define I(s, e, r) [GMPeerState##s][GMPeerEvent##e] = \
  { GMPeerRuleIgnore, GMPeerState##s, GMPeerActionNone, r }

static const GMPeerRule GMPeerRules[GMPeerStateCount][GMPeerEventCount] = {
  T(Idle, Invite, InvitingControl, SendControlInvitation),
  T(Idle, ControlInvitation, Accepted, AcceptControl),
  I(Idle, DataInvitation, "no control invitation came first"),
  I(Idle, ControlAccept, "not in a session"),
  I(Idle, DataAccept, "not in a session"),
  I(Idle, Reject, "not in a session"),
  I(Idle, End, "not in a session"),
  I(Idle, ClockSync0, "not in a session"),
  I(Idle, ClockSync1, "not in a session"),
  I(Idle, ClockSync2, "not in a session"),
  I(Idle, MIDIData, "not in a session"),
  I(Idle, Timeout, "no timers run before the session starts"),
  T(Idle, Close, Closed, None),

  I(InvitingControl, Invite, "already inviting"),
  I(InvitingControl, ControlInvitation, "we are the initiator"),
  I(InvitingControl, DataInvitation, "we are the initiator"),
  T(InvitingControl, ControlAccept, InvitingData, SendDataInvitation),
  I(InvitingControl, DataAccept, "data port not invited yet"),
  T(InvitingControl, Reject, Closed, Rejected),
  T(InvitingControl, End, Closed, RemoteEnded),
  I(InvitingControl, ClockSync0, "data port not set up"),
  I(InvitingControl, ClockSync1, "data port not set up"),
  I(InvitingControl, ClockSync2, "data port not set up"),
  I(InvitingControl, MIDIData, "data port not set up"),
  T(InvitingControl, Timeout, InvitingControl, Timers),
  T(InvitingControl, Close, Closed, LocalClose),

  I(InvitingData, Invite, "already inviting"),
  I(InvitingData, ControlInvitation, "we are the initiator"),
  I(InvitingData, DataInvitation, "we are the initiator"),
  I(InvitingData, ControlAccept, "repeated answer to a retried invitation"),
  T(InvitingData, DataAccept, Synchronising, StartClockSync),
  T(InvitingData, Reject, Closed, Rejected),
  T(InvitingData, End, Closed, RemoteEnded),
  I(InvitingData, ClockSync0, "data port not accepted yet"),
  I(InvitingData, ClockSync1, "data port not accepted yet"),
  I(InvitingData, ClockSync2, "data port not accepted yet"),
  I(InvitingData, MIDIData, "data port not accepted yet"),
  T(InvitingData, Timeout, InvitingData, Timers),
  T(InvitingData, Close, Closed, LocalClose),

  I(Accepted, Invite, "we are the responder"),
  T(Accepted, ControlInvitation, Accepted, ResendControlAccept),
  T(Accepted, DataInvitation, Synchronising, AcceptData),
  I(Accepted, ControlAccept, "we are the responder"),
  I(Accepted, DataAccept, "we are the responder"),
  I(Accepted, Reject, "we are the responder"),
  T(Accepted, End, Closed, RemoteEnded),
  I(Accepted, ClockSync0, "data port not set up"),
  I(Accepted, ClockSync1, "data port not set up"),
  I(Accepted, ClockSync2, "data port not set up"),
  I(Accepted, MIDIData, "data port not set up"),
  T(Accepted, Timeout, Accepted, Timers),
  T(Accepted, Close, Closed, LocalClose),

  I(Synchronising, Invite, "session already set up"),
  T(Synchronising, ControlInvitation, Synchronising, ResendControlAccept),
  T(Synchronising, DataInvitation, Synchronising, ResendDataAccept),
  I(Synchronising, ControlAccept, "repeated answer to a retried invitation"),
  I(Synchronising, DataAccept, "repeated answer to a retried invitation"),
  I(Synchronising, Reject, "a late NO after OK does not undo the session"),
  T(Synchronising, End, Closed, RemoteEnded),
  T(Synchronising, ClockSync0, Synchronising, AnswerClockSync),
  T(Synchronising, ClockSync1, Connected, FinishClockSync),
  T(Synchronising, ClockSync2, Connected, LearnLatency),
  T(Synchronising, MIDIData, Synchronising, DeliverMIDI),
  T(Synchronising, Timeout, Synchronising, Timers),
  T(Synchronising, Close, Closed, LocalClose),

  I(Connected, Invite, "session already set up"),
  T(Connected, ControlInvitation, Connected, ResendControlAccept),
  T(Connected, DataInvitation, Connected, ResendDataAccept),
  I(Connected, ControlAccept, "repeated answer to a retried invitation"),
  I(Connected, DataAccept, "repeated answer to a retried invitation"),
  I(Connected, Reject, "a late NO after OK does not undo the session"),
  T(Connected, End, Closed, RemoteEnded),
  T(Connected, ClockSync0, Connected, AnswerClockSync),
  T(Connected, ClockSync1, Connected, FinishClockSync),
  T(Connected, ClockSync2, Connected, LearnLatency),
  T(Connected, MIDIData, Connected, DeliverMIDI),
  T(Connected, Timeout, Connected, Timers),
  T(Connected, Close, Closed, LocalClose),

  I(Closed, Invite, "session over"),
  I(Closed, ControlInvitation, "session over"),
  I(Closed, DataInvitation, "session over"),
  I(Closed, ControlAccept, "session over"),
  I(Closed, DataAccept, "session over"),
  I(Closed, Reject, "session over"),
  I(Closed, End, "session over"),
  I(Closed, ClockSync0, "session over"),
  I(Closed, ClockSync1, "session over"),
  I(Closed, ClockSync2, "session over"),
  I(Closed, MIDIData, "session over"),
  I(Closed, Timeout, "session over"),
  I(Closed, Close, "session over"),
};
#undef T
#undef I

GMPeerRuleKind GMPeerRuleKindFor(GMPeerState s, GMPeerEvent e)
{
  return GMPeerRules[s][e].kind;
}

GMPeerState GMPeerRuleTargetFor(GMPeerState s, GMPeerEvent e)
{
  return GMPeerRules[s][e].target;
}

NSString *GMPeerRuleReasonFor(GMPeerState s, GMPeerEvent e)
{
  const char *r = GMPeerRules[s][e].reason;
  return r ? [NSString stringWithUTF8String: r] : nil;
}

NSString *GMPeerStateName(GMPeerState s)
{
  static NSString *names[GMPeerStateCount] = {
    @"idle", @"inviting-control", @"inviting-data", @"accepted",
    @"synchronising", @"connected", @"closed"
  };
  return (s >= 0 && s < GMPeerStateCount) ? names[s] : @"invalid";
}

NSString *GMPeerEventName(GMPeerEvent e)
{
  static NSString *names[GMPeerEventCount] = {
    @"invite", @"IN-control", @"IN-data", @"OK-control", @"OK-data", @"NO",
    @"BY", @"CK0", @"CK1", @"CK2", @"MIDI", @"timeout", @"close"
  };
  return (e >= 0 && e < GMPeerEventCount) ? names[e] : @"invalid";
}

/* Clock sync timestamps tick at 10 kHz. */
#define GM_TICKS_PER_SECOND 10000.0

@implementation GMPeerConnection
{
  NSString *_localName;
  NSTimeInterval _epoch;
  GMRTPMIDIEncoder *_encoder;
  GMRTPMIDIDecoder *_decoder;

  NSUInteger _attempts;            /* invitations or CK0s sent unanswered */
  NSTimeInterval _retryAt;         /* resend the pending invitation */
  NSTimeInterval _acceptedUntil;   /* responder: data IN must come by then */
  NSTimeInterval _syncTimeoutAt;   /* our CK0 is waiting for its CK1 */
  NSTimeInterval _nextSyncAt;      /* send the next CK0 */
  NSTimeInterval _feedbackAt;      /* send RS */
  NSUInteger _syncsDone;
  uint64_t _pendingSyncStamp;      /* timestamp1 of our unanswered CK0 */

  /* the event being handled, for the actions that need its payload */
  GMSessionMessage *_message;
  NSData *_packet;
  BOOL _controlPort;
}

- (instancetype) initWithRole: (GMPeerRole)role
                    localSSRC: (uint32_t)ssrc
                    localName: (NSString *)name
                   clockEpoch: (NSTimeInterval)epoch
{
  if ((self = [super init]) != nil)
    {
      _role = role;
      _localSSRC = ssrc;
      _localName = [name copy];
      _epoch = epoch;
      _latency = -1;
      _encoder = [[GMRTPMIDIEncoder alloc] initWithSSRC: ssrc
                                               sequence: (uint16_t)arc4random()];
      _decoder = [GMRTPMIDIDecoder new];
      /* Twelve tries a second apart is what other implementations do too,
       * so a peer that is just starting up is still reached. */
      _invitationRetryInterval = 1.0;
      _invitationAttempts = 12;
      _clockSyncTimeout = 2.0;
      _clockSyncAttempts = 3;
      _initialClockSyncInterval = 1.5;
      _initialClockSyncCount = 5;
      _clockSyncInterval = 10.0;
      _idleProbeInterval = 30.0;
      _feedbackInterval = 1.0;
    }
  return self;
}

- (uint64_t) ticksAt: (NSTimeInterval)now
{
  return (uint64_t)llround((now - _epoch) * GM_TICKS_PER_SECOND);
}

- (void) send: (GMSessionMessage *)m control: (BOOL)control
{
  [_delegate peer: self sendData: [m encodedData] onControlPort: control];
}

- (void) sendSessionCommand: (GMSessionCommand)c control: (BOOL)control
{
  [self send: [GMSessionMessage messageWithCommand: c
                                             token: _token
                                              ssrc: _localSSRC
                                              name: _localName]
     control: control];
}

/* Runs one event through the table.  The state is already the target while
 * the action runs, so an action can still override it (to Closed). */
- (void) fire: (GMPeerEvent)event at: (NSTimeInterval)now
{
  GMPeerRule rule = GMPeerRules[_state][event];
  GMPeerState before = _state;

  if (rule.kind != GMPeerRuleTransition) return;
  _state = rule.target;
  [self perform: rule.action at: now];
  if (_state != before)
    [_delegate peerDidChangeState: self];
}

- (void) closeWithReason: (GMPeerCloseReason)reason
                 sendBye: (BOOL)bye
{
  if (bye)
    {
      /* Peers treat the two ports as separate halves of the session and
       * only drop it once both have been ended. */
      [self sendSessionCommand: GMSessionCommandEnd control: YES];
      [self sendSessionCommand: GMSessionCommandEnd control: NO];
    }
  _state = GMPeerStateClosed;
  _closeReason = reason;
  _retryAt = _acceptedUntil = _syncTimeoutAt = _nextSyncAt = _feedbackAt = 0;
}

- (void) sendClockSyncAt: (NSTimeInterval)now
{
  _pendingSyncStamp = [self ticksAt: now];
  if (_pendingSyncStamp == 0) _pendingSyncStamp = 1; /* 0 means none pending */
  [self send: [GMSessionMessage clockSyncWithSSRC: _localSSRC count: 0
                                       timestamp1: _pendingSyncStamp
                                       timestamp2: 0 timestamp3: 0]
     control: NO];
  _syncTimeoutAt = now + _clockSyncTimeout;
  _nextSyncAt = 0;
}

- (void) scheduleNextSyncAt: (NSTimeInterval)now
{
  if (_role == GMPeerRoleInitiator)
    {
      _nextSyncAt = now + (_syncsDone < _initialClockSyncCount
        ? _initialClockSyncInterval : _clockSyncInterval);
    }
  else
    {
      /* The initiator keeps the clocks in sync; we only check that it is
       * still there when it has gone quiet. */
      _nextSyncAt = now + _idleProbeInterval;
    }
}

- (void) heardFromPeerAt: (NSTimeInterval)now
{
  if (_role == GMPeerRoleResponder && _syncTimeoutAt == 0
    && (_state == GMPeerStateSynchronising || _state == GMPeerStateConnected))
    {
      _nextSyncAt = now + _idleProbeInterval;
    }
}

- (void) perform: (GMPeerAction)action at: (NSTimeInterval)now
{
  GMSessionMessage *m = _message;

  switch (action)
    {
      case GMPeerActionNone:
        break;

      case GMPeerActionSendControlInvitation:
        _token = arc4random();
        _attempts = 1;
        [self sendSessionCommand: GMSessionCommandInvitation control: YES];
        _retryAt = now + _invitationRetryInterval;
        break;

      case GMPeerActionAcceptControl:
        _token = m.token;
        _remoteSSRC = m.ssrc;
        _remoteName = [m.name copy];
        [self sendSessionCommand: GMSessionCommandAccept control: YES];
        _acceptedUntil = now + _invitationRetryInterval * _invitationAttempts;
        break;

      case GMPeerActionResendControlAccept:
        if (_role == GMPeerRoleResponder)
          [self sendSessionCommand: GMSessionCommandAccept control: YES];
        break;

      case GMPeerActionAcceptData:
        [self sendSessionCommand: GMSessionCommandAccept control: NO];
        _acceptedUntil = 0;
        [self scheduleNextSyncAt: now];
        break;

      case GMPeerActionResendDataAccept:
        if (_role == GMPeerRoleResponder)
          [self sendSessionCommand: GMSessionCommandAccept control: NO];
        break;

      case GMPeerActionSendDataInvitation:
        _remoteSSRC = m.ssrc;
        _remoteName = [m.name copy];
        _attempts = 1;
        [self sendSessionCommand: GMSessionCommandInvitation control: NO];
        _retryAt = now + _invitationRetryInterval;
        break;

      case GMPeerActionStartClockSync:
        _retryAt = 0;
        _attempts = 1;
        [self sendClockSyncAt: now];
        break;

      case GMPeerActionRejected:
        [self closeWithReason: GMPeerCloseReasonRejected sendBye: NO];
        break;

      case GMPeerActionRemoteEnded:
        [self closeWithReason: GMPeerCloseReasonRemote sendBye: NO];
        break;

      case GMPeerActionAnswerClockSync:
        [self send: [GMSessionMessage clockSyncWithSSRC: _localSSRC count: 1
                                             timestamp1: m.timestamp1
                                             timestamp2: [self ticksAt: now]
                                             timestamp3: 0]
           control: NO];
        [self heardFromPeerAt: now];
        break;

      case GMPeerActionFinishClockSync:
        {
          uint64_t t3;
          if (_pendingSyncStamp == 0 || m.timestamp1 != _pendingSyncStamp)
            {
              /* An answer to a CK0 we gave up on: it says nothing about
               * the current round trip. */
              _state = (_syncsDone > 0) ? GMPeerStateConnected
                                        : GMPeerStateSynchronising;
              break;
            }
          t3 = [self ticksAt: now];
          if (t3 <= m.timestamp1) t3 = m.timestamp1 + 1;
          [self send: [GMSessionMessage clockSyncWithSSRC: _localSSRC count: 2
                                               timestamp1: m.timestamp1
                                               timestamp2: m.timestamp2
                                               timestamp3: t3]
             control: NO];
          _latency = (double)(t3 - m.timestamp1) / 2.0 / GM_TICKS_PER_SECOND;
          _pendingSyncStamp = 0;
          _syncTimeoutAt = 0;
          _attempts = 0;
          _syncsDone++;
          [self scheduleNextSyncAt: now];
        }
        break;

      case GMPeerActionLearnLatency:
        /* Both stamps are on the initiator's clock, so their difference is
         * the round trip as it measured it. */
        if (m.timestamp3 > m.timestamp1)
          _latency = (double)(m.timestamp3 - m.timestamp1) / 2.0
            / GM_TICKS_PER_SECOND;
        _syncsDone++;
        [self heardFromPeerAt: now];
        break;

      case GMPeerActionDeliverMIDI:
        {
          GMRTPHeader h;
          NSError *err = nil;
          NSArray *msgs = [_decoder messagesFromPacket: _packet header: &h
                                                 error: &err];
          _packetsReceived++;
          _sequenceGaps = [_decoder sequenceGaps];
          [self heardFromPeerAt: now];
          if (_feedbackAt == 0) _feedbackAt = now + _feedbackInterval;
          if (msgs == nil)
            {
              NSLog(@"gwmidid: dropped malformed packet from %@: %@",
                _remoteName, [err localizedDescription]);
            }
          else if ([msgs count] > 0)
            {
              [_delegate peer: self didReceiveMIDIMessages: msgs];
            }
        }
        break;

      case GMPeerActionTimers:
        [self runTimersAt: now];
        break;

      case GMPeerActionLocalClose:
        [self closeWithReason: GMPeerCloseReasonLocal sendBye: YES];
        break;
    }
}

- (void) runTimersAt: (NSTimeInterval)now
{
  if (_retryAt != 0 && now >= _retryAt)
    {
      if (_attempts >= _invitationAttempts)
        {
          [self closeWithReason: GMPeerCloseReasonTimeout sendBye: NO];
          return;
        }
      _attempts++;
      [self sendSessionCommand: GMSessionCommandInvitation
                       control: (_state == GMPeerStateInvitingControl)];
      _retryAt = now + _invitationRetryInterval;
    }
  if (_acceptedUntil != 0 && now >= _acceptedUntil)
    {
      [self closeWithReason: GMPeerCloseReasonTimeout sendBye: YES];
      return;
    }
  if (_syncTimeoutAt != 0 && now >= _syncTimeoutAt)
    {
      if (_attempts >= _clockSyncAttempts)
        {
          /* Nobody answers on the data port any more: the peer is gone
           * without saying goodbye. */
          [self closeWithReason: GMPeerCloseReasonTimeout sendBye: YES];
          return;
        }
      _attempts++;
      [self sendClockSyncAt: now];
    }
  if (_nextSyncAt != 0 && now >= _nextSyncAt)
    {
      _attempts = 1;
      [self sendClockSyncAt: now];
    }
  if (_feedbackAt != 0 && now >= _feedbackAt)
    {
      [self send: [GMSessionMessage feedbackWithSSRC: _localSSRC
                                            sequence: [_decoder lastSequence]]
         control: YES];
      _feedbackAt = 0;
    }
}

#pragma mark - Public entry points

- (void) inviteAt: (NSTimeInterval)now
{
  [self fire: GMPeerEventInvite at: now];
}

- (void) handleSessionMessage: (GMSessionMessage *)message
                onControlPort: (BOOL)control
                           at: (NSTimeInterval)now
{
  GMPeerEvent e;

  /* Only the IN that starts a responder's session may come from a stranger;
   * anything else has to carry this session's token or the peer's SSRC. */
  if (_state != GMPeerStateIdle && ![self ownsSessionMessage: message])
    return;
  switch (message.command)
    {
      case GMSessionCommandInvitation:
        e = control ? GMPeerEventControlInvitation : GMPeerEventDataInvitation;
        break;
      case GMSessionCommandAccept:
        e = control ? GMPeerEventControlAccept : GMPeerEventDataAccept;
        break;
      case GMSessionCommandReject: e = GMPeerEventReject; break;
      case GMSessionCommandEnd: e = GMPeerEventEnd; break;
      case GMSessionCommandClockSync:
        e = GMPeerEventClockSync0 + message.count;
        break;
      case GMSessionCommandFeedback:
        /* We keep no journal, so there is nothing to trim. */
        [self heardFromPeerAt: now];
        return;
      default:
        return;
    }
  _message = message;
  _controlPort = control;
  [self fire: e at: now];
  _message = nil;
}

- (void) handleRTPPacket: (NSData *)packet at: (NSTimeInterval)now
{
  _packet = packet;
  [self fire: GMPeerEventMIDIData at: now];
  _packet = nil;
}

- (BOOL) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now
{
  if (_state != GMPeerStateConnected && _state != GMPeerStateSynchronising)
    return NO;
  for (NSData *p in [_encoder packetsForMessages: messages
                                       timestamp: (uint32_t)[self ticksAt: now]])
    {
      [_delegate peer: self sendData: p onControlPort: NO];
      _packetsSent++;
    }
  return YES;
}

- (void) closeAt: (NSTimeInterval)now
{
  [self fire: GMPeerEventClose at: now];
}

- (NSTimeInterval) nextDeadline
{
  NSTimeInterval t[5] = { _retryAt, _acceptedUntil, _syncTimeoutAt,
                          _nextSyncAt, _feedbackAt };
  NSTimeInterval best = 0;
  int i;
  for (i = 0; i < 5; i++)
    if (t[i] != 0 && (best == 0 || t[i] < best)) best = t[i];
  return best;
}

- (void) fireTimersAt: (NSTimeInterval)now
{
  NSTimeInterval d = [self nextDeadline];
  if (d != 0 && now >= d)
    [self fire: GMPeerEventTimeout at: now];
}

- (BOOL) ownsSessionMessage: (GMSessionMessage *)m
{
  switch (m.command)
    {
      case GMSessionCommandInvitation:
      case GMSessionCommandAccept:
      case GMSessionCommandReject:
        return m.token == _token;
      case GMSessionCommandEnd:
        /* BY carries both; either identifies the session. */
        return m.token == _token
          || (_remoteSSRC != 0 && m.ssrc == _remoteSSRC);
      default:
        return _remoteSSRC != 0 && m.ssrc == _remoteSSRC;
    }
}

@end
