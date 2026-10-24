/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "GMPeerConnection.h"

@class GMLocalSession;

/* Who may join a session by inviting it. */
typedef NS_ENUM(NSInteger, GMConnectionPolicy) {
  GMConnectionPolicyAnyone = 0,
  GMConnectionPolicyDirectory,   /* only hosts the user listed */
  GMConnectionPolicyNobody       /* only connections we start ourselves */
};

GMConnectionPolicy GMConnectionPolicyFromString(NSString *s, BOOL *valid);
NSString *GMConnectionPolicyString(GMConnectionPolicy p);

@protocol GMSessionTransport <NSObject>
- (void) sendData: (NSData *)data to: (NSData *)address control: (BOOL)control;
@end

@protocol GMLocalSessionDelegate <NSObject>
- (BOOL) session: (GMLocalSession *)session
  directoryAllowsAddress: (NSData *)address
                    name: (NSString *)name;
- (void) session: (GMLocalSession *)session
  didReceiveMIDIMessages: (NSArray *)messages
                fromPeer: (GMPeerConnection *)peer;
- (void) sessionParticipantsDidChange: (GMLocalSession *)session;
- (void) sessionParticipantLatencyDidChange: (GMLocalSession *)session;
/* Before a closed participant is removed; its closeReason says why. */
- (void) session: (GMLocalSession *)session peerDidClose: (GMPeerConnection *)peer;
@end

/* One local endpoint: a name and a pair of UDP ports, with any number of
 * participants, both those that invited us and those we invited.  Pure
 * protocol logic like GMPeerConnection: datagrams come in through
 * -receiveDatagram:..., go out through the transport. */
@interface GMLocalSession : NSObject <GMPeerConnectionDelegate>

- (instancetype) initWithName: (NSString *)name
                         port: (uint16_t)controlPort
                         ssrc: (uint32_t)ssrc
                   clockEpoch: (NSTimeInterval)epoch;

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) uint32_t ssrc;
@property (nonatomic) GMConnectionPolicy policy;
@property (nonatomic, weak) id<GMLocalSessionDelegate> delegate;
@property (nonatomic, weak) id<GMSessionTransport> transport;
@property (nonatomic, readonly) NSArray *peers;

/* Applied to every new participant; tests shorten them. */
@property (nonatomic, copy) void (^peerConfiguration)(GMPeerConnection *peer);

- (void) receiveDatagram: (NSData *)data
                    from: (NSData *)address
               onControl: (BOOL)control
                      at: (NSTimeInterval)now;

/* address: the remote control port */
- (GMPeerConnection *) inviteAddress: (NSData *)address at: (NSTimeInterval)now;

/* To every participant whose session is up */
- (void) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now;

- (void) closePeer: (GMPeerConnection *)peer at: (NSTimeInterval)now;
- (void) closeAllAt: (NSTimeInterval)now;

- (NSTimeInterval) nextDeadline;
- (void) fireTimersAt: (NSTimeInterval)now;

@end
