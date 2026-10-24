/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

@class GMSessionMessage;
@class GMPeerConnection;

/* One participant of a session, seen from our side.  Pure protocol logic:
 * it never touches a socket or a clock.  The owner feeds it packets and the
 * current time, sends what it asks to send, and calls -fireTimersAt: when
 * -nextDeadline has passed.
 */

typedef NS_ENUM(NSInteger, GMPeerState) {
  GMPeerStateIdle = 0,
  GMPeerStateInvitingControl,  /* we sent IN on the control port */
  GMPeerStateInvitingData,     /* control accepted, we sent IN on data */
  GMPeerStateAccepted,         /* we accepted their control IN */
  GMPeerStateSynchronising,    /* both ports set up, clocks not yet synced */
  GMPeerStateConnected,
  GMPeerStateClosed,
  GMPeerStateCount
};

typedef NS_ENUM(NSInteger, GMPeerEvent) {
  GMPeerEventInvite = 0,          /* local: start inviting */
  GMPeerEventControlInvitation,   /* IN on control */
  GMPeerEventDataInvitation,      /* IN on data */
  GMPeerEventControlAccept,       /* OK on control */
  GMPeerEventDataAccept,          /* OK on data */
  GMPeerEventReject,              /* NO */
  GMPeerEventEnd,                 /* BY */
  GMPeerEventClockSync0,          /* CK count 0 */
  GMPeerEventClockSync1,
  GMPeerEventClockSync2,
  GMPeerEventMIDIData,            /* RTP MIDI packet */
  GMPeerEventTimeout,             /* a deadline passed */
  GMPeerEventClose,               /* local: end the session */
  GMPeerEventCount
};

typedef NS_ENUM(NSInteger, GMPeerRole) {
  GMPeerRoleInitiator = 0,
  GMPeerRoleResponder
};

typedef NS_ENUM(NSInteger, GMPeerCloseReason) {
  GMPeerCloseReasonNone = 0,
  GMPeerCloseReasonLocal,        /* we ended it */
  GMPeerCloseReasonRemote,       /* they sent BY */
  GMPeerCloseReasonRejected,     /* they sent NO */
  GMPeerCloseReasonTimeout       /* no answer: gone or unreachable */
};

/* What the state table says about one state x event pair. */
typedef NS_ENUM(NSInteger, GMPeerRuleKind) {
  GMPeerRuleUndecided = 0,
  GMPeerRuleTransition,
  GMPeerRuleIgnore
};

GMPeerRuleKind GMPeerRuleKindFor(GMPeerState state, GMPeerEvent event);
GMPeerState GMPeerRuleTargetFor(GMPeerState state, GMPeerEvent event);
NSString *GMPeerRuleReasonFor(GMPeerState state, GMPeerEvent event);
NSString *GMPeerStateName(GMPeerState state);
NSString *GMPeerEventName(GMPeerEvent event);

@protocol GMPeerConnectionDelegate <NSObject>
- (void) peer: (GMPeerConnection *)peer
     sendData: (NSData *)data
onControlPort: (BOOL)control;
- (void) peerDidChangeState: (GMPeerConnection *)peer;
- (void) peer: (GMPeerConnection *)peer didReceiveMIDIMessages: (NSArray *)messages;
@end

@interface GMPeerConnection : NSObject

/* clockEpoch: the instant our 10 kHz session clock counts from. */
- (instancetype) initWithRole: (GMPeerRole)role
                    localSSRC: (uint32_t)ssrc
                    localName: (NSString *)name
                   clockEpoch: (NSTimeInterval)epoch;

@property (nonatomic, weak) id<GMPeerConnectionDelegate> delegate;
@property (nonatomic, readonly) GMPeerRole role;
@property (nonatomic, readonly) GMPeerState state;
@property (nonatomic, readonly) GMPeerCloseReason closeReason;
@property (nonatomic, readonly) uint32_t localSSRC;
@property (nonatomic, readonly) uint32_t remoteSSRC;
@property (nonatomic, readonly) uint32_t token;
@property (nonatomic, readonly, copy) NSString *remoteName;

/* One-way latency from the last clock sync, negative until there was one. */
@property (nonatomic, readonly) NSTimeInterval latency;

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
- (void) handleSessionMessage: (GMSessionMessage *)message
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
- (BOOL) ownsSessionMessage: (GMSessionMessage *)message;

@end
