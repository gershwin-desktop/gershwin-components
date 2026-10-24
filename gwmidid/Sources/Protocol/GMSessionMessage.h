/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The session protocol that runs next to RTP MIDI on the control and the
 * data port.  Every packet starts with 0xFFFF and a two-letter command, so
 * it can never be mistaken for an RTP packet (whose first byte is 0x80).
 * All fields are big-endian.
 */
typedef NS_ENUM(uint16_t, GMSessionCommand) {
  GMSessionCommandInvitation = 0x494E, /* IN */
  GMSessionCommandAccept     = 0x4F4B, /* OK */
  GMSessionCommandReject     = 0x4E4F, /* NO */
  GMSessionCommandEnd        = 0x4259, /* BY */
  GMSessionCommandClockSync  = 0x434B, /* CK */
  GMSessionCommandFeedback   = 0x5253  /* RS */
};

/* The only protocol version in use by any known peer. */
#define GM_SESSION_PROTOCOL_VERSION 2u

extern NSString * const GMSessionMessageErrorDomain;

@interface GMSessionMessage : NSObject

@property (nonatomic) GMSessionCommand command;

/* IN, OK, NO, BY */
@property (nonatomic) uint32_t version;
@property (nonatomic) uint32_t token;
@property (nonatomic, copy) NSString *name;

/* All commands */
@property (nonatomic) uint32_t ssrc;

/* CK: count is 0, 1 or 2; the timestamps are in units of 100 microseconds
 * on the clock of whoever wrote them. */
@property (nonatomic) uint8_t count;
@property (nonatomic) uint64_t timestamp1;
@property (nonatomic) uint64_t timestamp2;
@property (nonatomic) uint64_t timestamp3;

/* RS: the highest RTP sequence number received */
@property (nonatomic) uint16_t feedbackSequence;

+ (BOOL) isSessionPacket: (NSData *)data;

+ (instancetype) messageWithCommand: (GMSessionCommand)command
                              token: (uint32_t)token
                               ssrc: (uint32_t)ssrc
                               name: (NSString *)name;
+ (instancetype) clockSyncWithSSRC: (uint32_t)ssrc
                             count: (uint8_t)count
                        timestamp1: (uint64_t)t1
                        timestamp2: (uint64_t)t2
                        timestamp3: (uint64_t)t3;
+ (instancetype) feedbackWithSSRC: (uint32_t)ssrc
                         sequence: (uint16_t)sequence;

/* Returns nil and sets error for anything that is not a well-formed
 * session packet. */
+ (instancetype) messageWithData: (NSData *)data error: (NSError **)error;

- (NSData *) encodedData;

@end
