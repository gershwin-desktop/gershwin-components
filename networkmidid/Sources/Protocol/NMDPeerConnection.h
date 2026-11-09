/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

@class NMDSessionMessage;
@class NMDPeerConnection;

/* One participant of a session, seen from our side.  Pure protocol logic:
 * it never touches a socket or a clock.  The owner feeds it packets and the
 * current time, sends what it asks to send, and calls -fireTimersAt: when
 * -nextDeadline has passed.
 */

typedef NS_ENUM(NSInteger, NMDPeerState) {
  NMDPeerStateIdle = 0,
  NMDPeerStateInvitingControl,  /* we sent IN on the control port */
  NMDPeerStateInvitingData,     /* control accepted, we sent IN on data */
  NMDPeerStateAccepted,         /* we accepted their control IN */
  NMDPeerStateSynchronising,    /* both ports set up, clocks not yet synced */
  NMDPeerStateConnected,
  NMDPeerStateClosed,
  NMDPeerStateCount
};

typedef NS_ENUM(NSInteger, NMDPeerEvent) {
  NMDPeerEventInvite = 0,          /* local: start inviting */
  NMDPeerEventControlInvitation,   /* IN on control */
  NMDPeerEventDataInvitation,      /* IN on data */
  NMDPeerEventControlAccept,       /* OK on control */
  NMDPeerEventDataAccept,          /* OK on data */
  NMDPeerEventReject,              /* NO */
  NMDPeerEventEnd,                 /* BY */
  NMDPeerEventClockSync0,          /* CK count 0 */
  NMDPeerEventClockSync1,
  NMDPeerEventClockSync2,
  NMDPeerEventMIDIData,            /* RTP MIDI packet */
  NMDPeerEventTimeout,             /* a deadline passed */
  NMDPeerEventClose,               /* local: end the session */
  NMDPeerEventCount
};

typedef NS_ENUM(NSInteger, NMDPeerRole) {
  NMDPeerRoleInitiator = 0,
  NMDPeerRoleResponder
};

typedef NS_ENUM(NSInteger, NMDPeerCloseReason) {
  NMDPeerCloseReasonNone = 0,
  NMDPeerCloseReasonLocal,        /* we ended it */
  NMDPeerCloseReasonRemote,       /* they sent BY */
  NMDPeerCloseReasonRejected,     /* they sent NO */
  NMDPeerCloseReasonTimeout       /* no answer: gone or unreachable */
};

/* What the state table says about one state x event pair. */
typedef NS_ENUM(NSInteger, NMDPeerRuleKind) {
  NMDPeerRuleUndecided = 0,
  NMDPeerRuleTransition,
  NMDPeerRuleIgnore
};

NMDPeerRuleKind NMDPeerRuleKindFor(NMDPeerState state, NMDPeerEvent event);
NMDPeerState NMDPeerRuleTargetFor(NMDPeerState state, NMDPeerEvent event);
NSString *NMDPeerRuleReasonFor(NMDPeerState state, NMDPeerEvent event);
NSString *NMDPeerStateName(NMDPeerState state);
NSString *NMDPeerEventName(NMDPeerEvent event);

@protocol NMDPeerConnectionDelegate <NSObject>
- (void) peer: (NMDPeerConnection *)peer
     sendData: (NSData *)data
onControlPort: (BOOL)control;
- (void) peerDidChangeState: (NMDPeerConnection *)peer;
/* After every clock sync, also those that do not change the state */
- (void) peerDidUpdateLatency: (NMDPeerConnection *)peer;
- (void) peer: (NMDPeerConnection *)peer didReceiveMIDIMessages: (NSArray *)messages;
@end

@interface NMDPeerConnection : NSObject

/* clockEpoch: the instant our 10 kHz session clock counts from. */
- (instancetype) initWithRole: (NMDPeerRole)role
                    localSSRC: (uint32_t)ssrc
                    localName: (NSString *)name
                   clockEpoch: (NSTimeInterval)epoch;

@property (nonatomic, weak) id<NMDPeerConnectionDelegate> delegate;
@property (nonatomic, readonly) NMDPeerRole role;
@property (nonatomic, readonly) NMDPeerState state;
@property (nonatomic, readonly) NMDPeerCloseReason closeReason;
@property (nonatomic, readonly) uint32_t localSSRC;
@property (nonatomic, readonly) uint32_t remoteSSRC;
@property (nonatomic, readonly) uint32_t token;
@property (nonatomic, readonly, copy) NSString *remoteName;

/* One-way latency, robust against single spikes (median of the last
 * clock syncs), negative until there was one. */
@property (nonatomic, readonly) NSTimeInterval latency;
/* The newest raw measurement, for debugging */
@property (nonatomic, readonly) NSTimeInterval lastLatencySample;

/* Owner's bookkeeping: where the peer's control and data ports are. */
@property (nonatomic, strong) id controlAddress;
@property (nonatomic, strong) id dataAddress;

/* Timing, adjustable so tests do not have to wait. */
@property (nonatomic) NSTimeInterval invitationRetryInterval;
@property (nonatomic) NSUInteger invitationAttempts;
@property (nonatomic) NSTimeInterval clockSyncTimeout;
@property (nonatomic) NSUInteger clockSyncAttempts;
@property (nonatomic) NSTimeInterval initialClockSyncInterval;
@property (nonatomic) NSUInteger initialClockSyncCount;
@property (nonatomic) NSTimeInterval clockSyncInterval;
@property (nonatomic) NSTimeInterval idleProbeInterval;
@property (nonatomic) NSTimeInterval feedbackInterval;

/* Packets counted for the control interface */
@property (nonatomic, readonly) NSUInteger packetsSent;
@property (nonatomic, readonly) NSUInteger packetsReceived;
@property (nonatomic, readonly) NSUInteger sequenceGaps;

/* Initiator: start the invitation with a fresh token. */
- (void) inviteAt: (NSTimeInterval)now;

/* An incoming session packet; for a responder the first one is the IN that
 * made the owner create this peer. */
- (void) handleSessionMessage: (NMDSessionMessage *)message
                onControlPort: (BOOL)control
                           at: (NSTimeInterval)now;

- (void) handleRTPPacket: (NSData *)packet at: (NSTimeInterval)now;

/* Sends the messages if the session is up; returns NO otherwise. */
- (BOOL) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now;

/* Ends the session, telling the peer when it knows about us. */
- (void) closeAt: (NSTimeInterval)now;

/* Absolute time of the next timer, or 0 when nothing is pending. */
- (NSTimeInterval) nextDeadline;
- (void) fireTimersAt: (NSTimeInterval)now;

/* Whether this datagram belongs to this peer's session, by token on IN/OK/
 * NO/BY and by SSRC otherwise. */
- (BOOL) ownsSessionMessage: (NMDSessionMessage *)message;

@end
