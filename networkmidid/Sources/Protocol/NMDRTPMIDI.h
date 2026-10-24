/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* RTP MIDI payload (RFC 6295) on top of a 12-byte RTP header.
 *
 * Messages on both sides of this codec are complete MIDI messages, one per
 * NSData, starting with their status byte; a system exclusive message runs
 * from F0 to F7.  Segmenting long sysex into several packets and putting it
 * back together is the codec's job, so nothing above it ever sees a
 * fragment.
 */

/* Payload type 97 is the dynamic type every known peer uses. */
#define NMD_RTP_MIDI_PAYLOAD_TYPE 0x61

/* The command section length field is 12 bits wide. */
#define NMD_RTP_MIDI_MAX_COMMAND_SECTION 4095

/* A sysex above this size is dropped rather than buffered without limit. */
#define NMD_RTP_MIDI_MAX_SYSEX 65536

extern NSString * const NMDRTPMIDIErrorDomain;

typedef struct {
  uint16_t sequence;
  uint32_t timestamp;
  uint32_t ssrc;
  uint8_t payloadType;
  BOOL hasJournal;
} NMDRTPHeader;

/* Total length of the recovery journal at the start of bytes, or -1 when the
 * journal is malformed or runs past len.  Used to skip journals of peers
 * that send one; this daemon never sends one itself. */
NSInteger NMDRTPMIDIJournalLength(const uint8_t *bytes, NSUInteger len);

@interface NMDRTPMIDIEncoder : NSObject

- (instancetype) initWithSSRC: (uint32_t)ssrc sequence: (uint16_t)firstSequence;

@property (nonatomic, readonly) uint32_t ssrc;
@property (nonatomic, readonly) uint16_t nextSequence;

/* Omitting repeated channel status bytes saves a byte per message; on by
 * default since RFC 6295 requires every receiver to handle it. */
@property (nonatomic) BOOL usesRunningStatus;

/* Upper bound for one packet's command section; packets have to stay well
 * below the path MTU because nothing fragments them for us. */
@property (nonatomic) NSUInteger maxCommandSectionLength;

/* All messages go out with a delta time of zero: they are sent the moment
 * they arrive, so there is no time to spread between them. */
- (NSArray *) packetsForMessages: (NSArray *)messages
                       timestamp: (uint32_t)timestamp;

@end

@interface NMDRTPMIDIDecoder : NSObject

/* Packets whose journal was present and skipped */
@property (nonatomic, readonly) NSUInteger journalsSkipped;
/* Packets with a sequence number other than the one after the last */
@property (nonatomic, readonly) NSUInteger sequenceGaps;
@property (nonatomic, readonly) BOOL hasReceived;
@property (nonatomic, readonly) uint16_t lastSequence;

/* Reads the RTP header only. */
+ (BOOL) parseHeader: (NSData *)packet
              header: (NMDRTPHeader *)header
       payloadOffset: (NSUInteger *)offset
               error: (NSError **)error;

/* Returns the complete messages in the packet (possibly none, when it only
 * carried part of a sysex), or nil with an error for a malformed packet. */
- (NSArray *) messagesFromPacket: (NSData *)packet
                          header: (NMDRTPHeader *)header
                           error: (NSError **)error;

@end
