/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDSessionMessage.h"
#import "NMDByteOrder.h"

NSString * const NMDSessionMessageErrorDomain = @"NMDSessionMessageErrorDomain";

/* Signature, command, version, token, SSRC */
#define NMD_INVITATION_HEADER_LENGTH 16
/* Signature, command, SSRC, count, 3 padding bytes, three 64-bit stamps */
#define NMD_CLOCK_SYNC_LENGTH 36
/* Signature, command, SSRC, sequence number (16 bits) plus 16 padding bits */
#define NMD_FEEDBACK_LENGTH 12

static NSError *NMDSessionError(NSString *reason)
{
  return [NSError errorWithDomain: NMDSessionMessageErrorDomain
                             code: 1
                         userInfo: @{NSLocalizedDescriptionKey: reason}];
}

@implementation NMDSessionMessage

+ (BOOL) isSessionPacket: (NSData *)data
{
  const uint8_t *b = [data bytes];
  return [data length] >= 4 && b[0] == 0xFF && b[1] == 0xFF;
}

+ (instancetype) messageWithCommand: (NMDSessionCommand)command
                              token: (uint32_t)token
                               ssrc: (uint32_t)ssrc
                               name: (NSString *)name
{
  NMDSessionMessage *m = [self new];
  m.command = command;
  m.version = NMD_SESSION_PROTOCOL_VERSION;
  m.token = token;
  m.ssrc = ssrc;
  m.name = name;
  return m;
}

+ (instancetype) clockSyncWithSSRC: (uint32_t)ssrc
                             count: (uint8_t)count
                        timestamp1: (uint64_t)t1
                        timestamp2: (uint64_t)t2
                        timestamp3: (uint64_t)t3
{
  NMDSessionMessage *m = [self new];
  m.command = NMDSessionCommandClockSync;
  m.ssrc = ssrc;
  m.count = count;
  m.timestamp1 = t1;
  m.timestamp2 = t2;
  m.timestamp3 = t3;
  return m;
}

+ (instancetype) feedbackWithSSRC: (uint32_t)ssrc sequence: (uint16_t)sequence
{
  NMDSessionMessage *m = [self new];
  m.command = NMDSessionCommandFeedback;
  m.ssrc = ssrc;
  m.feedbackSequence = sequence;
  return m;
}

+ (instancetype) messageWithData: (NSData *)data error: (NSError **)error
{
  const uint8_t *b = [data bytes];
  NSUInteger len = [data length];
  NMDSessionMessage *m;

  if (![self isSessionPacket: data])
    {
      if (error) *error = NMDSessionError(@"not a session packet");
      return nil;
    }
  m = [self new];
  m.command = (NMDSessionCommand)NMDReadBE16(b + 2);
  switch (m.command)
    {
      case NMDSessionCommandInvitation:
      case NMDSessionCommandAccept:
      case NMDSessionCommandReject:
      case NMDSessionCommandEnd:
        if (len < NMD_INVITATION_HEADER_LENGTH)
          {
            if (error) *error = NMDSessionError(@"session packet too short");
            return nil;
          }
        m.version = NMDReadBE32(b + 4);
        m.token = NMDReadBE32(b + 8);
        m.ssrc = NMDReadBE32(b + 12);
        if (len > NMD_INVITATION_HEADER_LENGTH)
          {
            const uint8_t *s = b + NMD_INVITATION_HEADER_LENGTH;
            NSUInteger max = len - NMD_INVITATION_HEADER_LENGTH;
            const uint8_t *nul = memchr(s, 0, max);
            /* Peers terminate the name with a NUL; a peer that sends the
             * name up to the end of the datagram means the same thing. */
            NSUInteger n = nul ? (NSUInteger)(nul - s) : max;
            if (n > 0)
              {
                m.name = [[NSString alloc] initWithBytes: s
                                                  length: n
                                                encoding: NSUTF8StringEncoding];
              }
          }
        return m;

      case NMDSessionCommandClockSync:
        if (len < NMD_CLOCK_SYNC_LENGTH)
          {
            if (error) *error = NMDSessionError(@"clock sync packet too short");
            return nil;
          }
        m.ssrc = NMDReadBE32(b + 4);
        m.count = b[8];
        if (m.count > 2)
          {
            if (error) *error = NMDSessionError(@"clock sync count out of range");
            return nil;
          }
        m.timestamp1 = NMDReadBE64(b + 12);
        m.timestamp2 = NMDReadBE64(b + 20);
        m.timestamp3 = NMDReadBE64(b + 28);
        return m;

      case NMDSessionCommandFeedback:
        if (len < NMD_FEEDBACK_LENGTH)
          {
            if (error) *error = NMDSessionError(@"feedback packet too short");
            return nil;
          }
        m.ssrc = NMDReadBE32(b + 4);
        m.feedbackSequence = NMDReadBE16(b + 8);
        return m;
    }
  if (error) *error = NMDSessionError(@"unknown session command");
  return nil;
}

- (NSData *) encodedData
{
  NSMutableData *d;
  uint8_t *b;

  switch (self.command)
    {
      case NMDSessionCommandInvitation:
      case NMDSessionCommandAccept:
      case NMDSessionCommandReject:
      case NMDSessionCommandEnd:
        {
          NSData *nameData = [self.name dataUsingEncoding: NSUTF8StringEncoding];
          /* BY carries no name; the others carry it NUL-terminated. */
          BOOL withName = (self.command != NMDSessionCommandEnd && nameData != nil);
          NSUInteger len = NMD_INVITATION_HEADER_LENGTH
            + (withName ? [nameData length] + 1 : 0);
          d = [NSMutableData dataWithLength: len];
          b = [d mutableBytes];
          b[0] = b[1] = 0xFF;
          NMDWriteBE16(b + 2, self.command);
          NMDWriteBE32(b + 4, self.version);
          NMDWriteBE32(b + 8, self.token);
          NMDWriteBE32(b + 12, self.ssrc);
          if (withName)
            {
              memcpy(b + NMD_INVITATION_HEADER_LENGTH, [nameData bytes],
                [nameData length]);
            }
          return d;
        }
      case NMDSessionCommandClockSync:
        d = [NSMutableData dataWithLength: NMD_CLOCK_SYNC_LENGTH];
        b = [d mutableBytes];
        b[0] = b[1] = 0xFF;
        NMDWriteBE16(b + 2, self.command);
        NMDWriteBE32(b + 4, self.ssrc);
        b[8] = self.count;
        NMDWriteBE64(b + 12, self.timestamp1);
        NMDWriteBE64(b + 20, self.timestamp2);
        NMDWriteBE64(b + 28, self.timestamp3);
        return d;
      case NMDSessionCommandFeedback:
        d = [NSMutableData dataWithLength: NMD_FEEDBACK_LENGTH];
        b = [d mutableBytes];
        b[0] = b[1] = 0xFF;
        NMDWriteBE16(b + 2, self.command);
        NMDWriteBE32(b + 4, self.ssrc);
        NMDWriteBE16(b + 8, self.feedbackSequence);
        return d;
    }
  [NSException raise: NSInternalInconsistencyException
              format: @"NMDSessionMessage: cannot encode command 0x%04x",
                      (unsigned)self.command];
  return nil;
}

- (NSString *) description
{
  char c[3] = { (char)(self.command >> 8), (char)(self.command & 0xFF), 0 };
  if (self.command == NMDSessionCommandClockSync)
    {
      return [NSString stringWithFormat:
        @"<CK ssrc=%08x count=%u t=%llu/%llu/%llu>", self.ssrc, self.count,
        (unsigned long long)self.timestamp1,
        (unsigned long long)self.timestamp2,
        (unsigned long long)self.timestamp3];
    }
  if (self.command == NMDSessionCommandFeedback)
    {
      return [NSString stringWithFormat: @"<RS ssrc=%08x seq=%u>",
        self.ssrc, self.feedbackSequence];
    }
  return [NSString stringWithFormat: @"<%s token=%08x ssrc=%08x name=%@>",
    c, self.token, self.ssrc, self.name];
}

@end
