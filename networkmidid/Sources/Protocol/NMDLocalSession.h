/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "NMDPeerConnection.h"

@class NMDLocalSession;

/* Who may join a session by inviting it. */
typedef NS_ENUM(NSInteger, NMDConnectionPolicy) {
  NMDConnectionPolicyAnyone = 0,
  NMDConnectionPolicyDirectory,   /* only hosts the user listed */
  NMDConnectionPolicyNobody       /* only connections we start ourselves */
};

NMDConnectionPolicy NMDConnectionPolicyFromString(NSString *s, BOOL *valid);
NSString *NMDConnectionPolicyString(NMDConnectionPolicy p);

@protocol NMDSessionTransport <NSObject>
- (void) sendData: (NSData *)data to: (NSData *)address control: (BOOL)control;
@end

@protocol NMDLocalSessionDelegate <NSObject>
- (BOOL) session: (NMDLocalSession *)session
  directoryAllowsAddress: (NSData *)address
                    name: (NSString *)name;
- (void) session: (NMDLocalSession *)session
  didReceiveMIDIMessages: (NSArray *)messages
                fromPeer: (NMDPeerConnection *)peer;
- (void) sessionParticipantsDidChange: (NMDLocalSession *)session;
- (void) sessionParticipantLatencyDidChange: (NMDLocalSession *)session;
/* Before a closed participant is removed; its closeReason says why. */
- (void) session: (NMDLocalSession *)session peerDidClose: (NMDPeerConnection *)peer;
@end

/* One local endpoint: a name and a pair of UDP ports, with any number of
 * participants, both those that invited us and those we invited.  Pure
 * protocol logic like NMDPeerConnection: datagrams come in through
 * -receiveDatagram:..., go out through the transport. */
@interface NMDLocalSession : NSObject <NMDPeerConnectionDelegate>

- (instancetype) initWithName: (NSString *)name
                         port: (uint16_t)controlPort
                         ssrc: (uint32_t)ssrc
                   clockEpoch: (NSTimeInterval)epoch;

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) uint32_t ssrc;
@property (nonatomic) NMDConnectionPolicy policy;
@property (nonatomic, weak) id<NMDLocalSessionDelegate> delegate;
@property (nonatomic, weak) id<NMDSessionTransport> transport;
@property (nonatomic, readonly) NSArray *peers;

/* Applied to every new participant; tests shorten them. */
@property (nonatomic, copy) void (^peerConfiguration)(NMDPeerConnection *peer);

- (void) receiveDatagram: (NSData *)data
                    from: (NSData *)address
               onControl: (BOOL)control
                      at: (NSTimeInterval)now;

/* address: the remote control port */
- (NMDPeerConnection *) inviteAddress: (NSData *)address at: (NSTimeInterval)now;

/* To every participant whose session is up */
- (void) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now;

- (void) closePeer: (NMDPeerConnection *)peer at: (NSTimeInterval)now;
- (void) closeAllAt: (NSTimeInterval)now;

- (NSTimeInterval) nextDeadline;
- (void) fireTimersAt: (NSTimeInterval)now;

@end
