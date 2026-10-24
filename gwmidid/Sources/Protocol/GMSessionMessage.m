/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMSessionMessage.h"
#import "GMByteOrder.h"

NSString * const GMSessionMessageErrorDomain = @"GMSessionMessageErrorDomain";

/* Signature, command, version, token, SSRC */
#define GM_INVITATION_HEADER_LENGTH 16
/* Signature, command, SSRC, count, 3 padding bytes, three 64-bit stamps */
#define GM_CLOCK_SYNC_LENGTH 36
/* Signature, command, SSRC, sequence number (16 bits) plus 16 padding bits */
#define GM_FEEDBACK_LENGTH 12

static NSError *GMSessionError(NSString *reason)
{
  return [NSError errorWithDomain: GMSessionMessageErrorDomain
                             code: 1
                         userInfo: @{NSLocalizedDescriptionKey: reason}];
}

@implementation GMSessionMessage

+ (BOOL) isSessionPacket: (NSData *)data
{
  const uint8_t *b = [data bytes];
  return [data length] >= 4 && b[0] == 0xFF && b[1] == 0xFF;
}

+ (instancetype) messageWithCommand: (GMSessionCommand)command
                              token: (uint32_t)token
                               ssrc: (uint32_t)ssrc
                               name: (NSString *)name
{
  GMSessionMessage *m = [self new];
  m.command = command;
  m.version = GM_SESSION_PROTOCOL_VERSION;
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
  GMSessionMessage *m = [self new];
  m.command = GMSessionCommandClockSync;
  m.ssrc = ssrc;
  m.count = count;
  m.timestamp1 = t1;
  m.timestamp2 = t2;
  m.timestamp3 = t3;
  return m;
}

+ (instancetype) feedbackWithSSRC: (uint32_t)ssrc sequence: (uint16_t)sequence
{
  GMSessionMessage *m = [self new];
  m.command = GMSessionCommandFeedback;
  m.ssrc = ssrc;
  m.feedbackSequence = sequence;
  return m;
}

+ (instancetype) messageWithData: (NSData *)data error: (NSError **)error
{
  const uint8_t *b = [data bytes];
  NSUInteger len = [data length];
  GMSessionMessage *m;

  if (![self isSessionPacket: data])
    {
      if (error) *error = GMSessionError(@"not a session packet");
      return nil;
    }
  m = [self new];
  m.command = (GMSessionCommand)GMReadBE16(b + 2);
  switch (m.command)
    {
      case GMSessionCommandInvitation:
      case GMSessionCommandAccept:
      case GMSessionCommandReject:
      case GMSessionCommandEnd:
        if (len < GM_INVITATION_HEADER_LENGTH)
          {
            if (error) *error = GMSessionError(@"session packet too short");
            return nil;
          }
        m.version = GMReadBE32(b + 4);
        m.token = GMReadBE32(b + 8);
        m.ssrc = GMReadBE32(b + 12);
        if (len > GM_INVITATION_HEADER_LENGTH)
          {
            const uint8_t *s = b + GM_INVITATION_HEADER_LENGTH;
            NSUInteger max = len - GM_INVITATION_HEADER_LENGTH;
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

      case GMSessionCommandClockSync:
        if (len < GM_CLOCK_SYNC_LENGTH)
          {
            if (error) *error = GMSessionError(@"clock sync packet too short");
            return nil;
          }
        m.ssrc = GMReadBE32(b + 4);
        m.count = b[8];
        if (m.count > 2)
          {
            if (error) *error = GMSessionError(@"clock sync count out of range");
            return nil;
          }
        m.timestamp1 = GMReadBE64(b + 12);
        m.timestamp2 = GMReadBE64(b + 20);
        m.timestamp3 = GMReadBE64(b + 28);
        return m;

      case GMSessionCommandFeedback:
        if (len < GM_FEEDBACK_LENGTH)
          {
            if (error) *error = GMSessionError(@"feedback packet too short");
            return nil;
          }
        m.ssrc = GMReadBE32(b + 4);
        m.feedbackSequence = GMReadBE16(b + 8);
        return m;
    }
  if (error) *error = GMSessionError(@"unknown session command");
  return nil;
}

- (NSData *) encodedData
{
  NSMutableData *d;
  uint8_t *b;

  switch (self.command)
    {
      case GMSessionCommandInvitation:
      case GMSessionCommandAccept:
      case GMSessionCommandReject:
      case GMSessionCommandEnd:
        {
          NSData *nameData = [self.name dataUsingEncoding: NSUTF8StringEncoding];
          /* BY carries no name; the others carry it NUL-terminated. */
          BOOL withName = (self.command != GMSessionCommandEnd && nameData != nil);
          NSUInteger len = GM_INVITATION_HEADER_LENGTH
            + (withName ? [nameData length] + 1 : 0);
          d = [NSMutableData dataWithLength: len];
          b = [d mutableBytes];
          b[0] = b[1] = 0xFF;
          GMWriteBE16(b + 2, self.command);
          GMWriteBE32(b + 4, self.version);
          GMWriteBE32(b + 8, self.token);
          GMWriteBE32(b + 12, self.ssrc);
          if (withName)
            {
              memcpy(b + GM_INVITATION_HEADER_LENGTH, [nameData bytes],
                [nameData length]);
            }
          return d;
        }
      case GMSessionCommandClockSync:
        d = [NSMutableData dataWithLength: GM_CLOCK_SYNC_LENGTH];
        b = [d mutableBytes];
        b[0] = b[1] = 0xFF;
        GMWriteBE16(b + 2, self.command);
        GMWriteBE32(b + 4, self.ssrc);
        b[8] = self.count;
        GMWriteBE64(b + 12, self.timestamp1);
        GMWriteBE64(b + 20, self.timestamp2);
        GMWriteBE64(b + 28, self.timestamp3);
        return d;
      case GMSessionCommandFeedback:
        d = [NSMutableData dataWithLength: GM_FEEDBACK_LENGTH];
        b = [d mutableBytes];
        b[0] = b[1] = 0xFF;
        GMWriteBE16(b + 2, self.command);
        GMWriteBE32(b + 4, self.ssrc);
        GMWriteBE16(b + 8, self.feedbackSequence);
        return d;
    }
  [NSException raise: NSInternalInconsistencyException
              format: @"GMSessionMessage: cannot encode command 0x%04x",
                      (unsigned)self.command];
  return nil;
}

- (NSString *) description
{
  char c[3] = { (char)(self.command >> 8), (char)(self.command & 0xFF), 0 };
  if (self.command == GMSessionCommandClockSync)
    {
      return [NSString stringWithFormat:
        @"<CK ssrc=%08x count=%u t=%llu/%llu/%llu>", self.ssrc, self.count,
        (unsigned long long)self.timestamp1,
        (unsigned long long)self.timestamp2,
        (unsigned long long)self.timestamp3];
    }
  if (self.command == GMSessionCommandFeedback)
    {
      return [NSString stringWithFormat: @"<RS ssrc=%08x seq=%u>",
        self.ssrc, self.feedbackSequence];
    }
  return [NSString stringWithFormat: @"<%s token=%08x ssrc=%08x name=%@>",
    c, self.token, self.ssrc, self.name];
}

@end
