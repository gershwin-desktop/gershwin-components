/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDRTPMIDI.h"
#import "NMDByteOrder.h"

NSString * const NMDRTPMIDIErrorDomain = @"NMDRTPMIDIErrorDomain";

#define NMD_RTP_HEADER_LENGTH 12

/* Command section header bits (RFC 6295, 3.1) */
#define NMD_SECTION_B 0x80 /* 12-bit length follows in two bytes */
#define NMD_SECTION_J 0x40 /* a recovery journal follows the commands */
#define NMD_SECTION_Z 0x20 /* the first command has a delta time */
#define NMD_SECTION_P 0x10 /* status of the first command was a phantom */

/* Sysex segments are not split below this size: a packet that has only a
 * few bytes left is better sent as it is and the segment started fresh. */
#define NMD_MIN_SYSEX_SEGMENT 16

static NSError *NMDRTPError(NSString *reason)
{
  return [NSError errorWithDomain: NMDRTPMIDIErrorDomain
                             code: 1
                         userInfo: @{NSLocalizedDescriptionKey: reason}];
}

/* Number of data bytes after a status byte; -1 for sysex (variable) and for
 * the undefined system common codes, which carry no defined length. */
static int NMDDataLength(uint8_t status)
{
  switch (status & 0xF0)
    {
      case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 2;
      case 0xC0: case 0xD0: return 1;
      default: break;
    }
  switch (status)
    {
      case 0xF1: case 0xF3: return 1;
      case 0xF2: return 2;
      case 0xF6: return 0;
      default: break;
    }
  if (status >= 0xF8) return 0;
  return -1;
}

NSInteger NMDRTPMIDIJournalLength(const uint8_t *b, NSUInteger len)
{
  NSUInteger pos = 3;
  BOOL hasSystem, hasChannels;
  unsigned channels, i;

  if (len < 3) return -1;
  hasSystem = (b[0] & 0x40) != 0;
  hasChannels = (b[0] & 0x20) != 0;
  channels = (b[0] & 0x0F) + 1u;
  if (hasSystem)
    {
      NSUInteger sl;
      if (pos + 2 > len) return -1;
      sl = ((NSUInteger)(b[pos] & 0x03) << 8) | b[pos + 1];
      if (sl < 2 || pos + sl > len) return -1;
      pos += sl;
    }
  if (hasChannels)
    {
      for (i = 0; i < channels; i++)
        {
          NSUInteger cl;
          if (pos + 3 > len) return -1;
          cl = ((NSUInteger)(b[pos] & 0x03) << 8) | b[pos + 1];
          if (cl < 3 || pos + cl > len) return -1;
          pos += cl;
        }
    }
  return (NSInteger)pos;
}

@implementation NMDRTPMIDIEncoder
{
  uint16_t _sequence;
}

- (instancetype) initWithSSRC: (uint32_t)ssrc sequence: (uint16_t)firstSequence
{
  if ((self = [super init]) != nil)
    {
      _ssrc = ssrc;
      _sequence = firstSequence;
      _usesRunningStatus = YES;
      _maxCommandSectionLength = 1000;
    }
  return self;
}

- (uint16_t) nextSequence
{
  return _sequence;
}

- (NSData *) packetWithCommands: (NSData *)commands timestamp: (uint32_t)ts
{
  NSUInteger cl = [commands length];
  NSUInteger hl = (cl > 15) ? 2 : 1;
  NSMutableData *p = [NSMutableData dataWithLength: NMD_RTP_HEADER_LENGTH + hl + cl];
  uint8_t *b = [p mutableBytes];

  b[0] = 0x80; /* version 2, no padding, no extension, no CSRC */
  b[1] = NMD_RTP_MIDI_PAYLOAD_TYPE;
  NMDWriteBE16(b + 2, _sequence++);
  NMDWriteBE32(b + 4, ts);
  NMDWriteBE32(b + 8, _ssrc);
  if (hl == 2)
    {
      b[12] = (uint8_t)(NMD_SECTION_B | (cl >> 8));
      b[13] = (uint8_t)(cl & 0xFF);
    }
  else
    {
      b[12] = (uint8_t)cl;
    }
  memcpy(b + NMD_RTP_HEADER_LENGTH + hl, [commands bytes], cl);
  return p;
}

- (NSArray *) packetsForMessages: (NSArray *)messages
                       timestamp: (uint32_t)timestamp
{
  NSMutableArray *packets = [NSMutableArray array];
  NSMutableData *cmd = [NSMutableData data];
  NSUInteger max = _maxCommandSectionLength;
  uint8_t running = 0;
  static const uint8_t zeroDelta = 0;

  if (max > NMD_RTP_MIDI_MAX_COMMAND_SECTION) max = NMD_RTP_MIDI_MAX_COMMAND_SECTION;
  if (max < 4 * NMD_MIN_SYSEX_SEGMENT)
    {
      [NSException raise: NSInvalidArgumentException
                  format: @"maxCommandSectionLength %lu too small",
                          (unsigned long)max];
    }

#define FLUSH() do { \
    if ([cmd length] > 0) { \
      [packets addObject: [self packetWithCommands: cmd timestamp: timestamp]]; \
      [cmd setLength: 0]; \
    } \
    running = 0; \
  } while (0)
/* Every command but the first in a packet is preceded by its delta time. */
#define DELTA() do { if ([cmd length] > 0) [cmd appendBytes: &zeroDelta length: 1]; } while (0)

  for (NSData *msg in messages)
    {
      const uint8_t *m = [msg bytes];
      NSUInteger len = [msg length];
      uint8_t status;

      if (len == 0) continue;
      status = m[0];
      if (status < 0x80)
        {
          [NSException raise: NSInvalidArgumentException
                      format: @"MIDI message without status byte"];
        }

      if (status == 0xF0)
        {
          const uint8_t *body = m + 1;
          NSUInteger remaining;
          BOOL firstSegment = YES;

          if (len < 2 || m[len - 1] != 0xF7)
            {
              [NSException raise: NSInvalidArgumentException
                          format: @"sysex message not terminated by F7"];
            }
          remaining = len - 2;
          for (;;)
            {
              NSUInteger overhead = ([cmd length] > 0 ? 1 : 0) + 2;
              NSUInteger space = (max > [cmd length] + overhead)
                ? max - [cmd length] - overhead : 0;
              uint8_t lead = firstSegment ? 0xF0 : 0xF7;

              if (remaining <= space)
                {
                  static const uint8_t end = 0xF7;
                  DELTA();
                  [cmd appendBytes: &lead length: 1];
                  [cmd appendBytes: body length: remaining];
                  [cmd appendBytes: &end length: 1];
                  break;
                }
              if (space < NMD_MIN_SYSEX_SEGMENT)
                {
                  FLUSH();
                  continue;
                }
              {
                /* A segment that does not end the sysex ends in F0, and
                 * the next one in the next packet starts with F7. */
                static const uint8_t more = 0xF0;
                DELTA();
                [cmd appendBytes: &lead length: 1];
                [cmd appendBytes: body length: space];
                [cmd appendBytes: &more length: 1];
                body += space;
                remaining -= space;
                firstSegment = NO;
                FLUSH();
              }
            }
          running = 0;
          continue;
        }

      if (status >= 0xF8)
        {
          if ([cmd length] + 2 > max) FLUSH();
          DELTA();
          [cmd appendBytes: m length: 1];
          /* real-time messages leave running status alone */
          continue;
        }

      {
        int dl = NMDDataLength(status);
        BOOL omit;
        NSUInteger need;

        if (dl < 0 || (NSUInteger)dl + 1 != len)
          {
            [NSException raise: NSInvalidArgumentException
                        format: @"MIDI message 0x%02x has length %lu",
                                status, (unsigned long)len];
          }
        omit = (_usesRunningStatus && status < 0xF0 && status == running
          && [cmd length] > 0);
        need = ([cmd length] > 0 ? 1 : 0) + (omit ? len - 1 : len);
        if ([cmd length] + need > max)
          {
            FLUSH();
            omit = NO;
          }
        DELTA();
        if (omit)
          [cmd appendBytes: m + 1 length: len - 1];
        else
          [cmd appendBytes: m length: len];
        running = (status < 0xF0) ? status : 0;
      }
    }
  FLUSH();
#undef FLUSH
#undef DELTA
  return packets;
}

@end

@implementation NMDRTPMIDIDecoder
{
  NSMutableData *_sysex;
  BOOL _sysexDiscarding;
}

+ (BOOL) parseHeader: (NSData *)packet
              header: (NMDRTPHeader *)header
       payloadOffset: (NSUInteger *)offset
               error: (NSError **)error
{
  const uint8_t *b = [packet bytes];
  NSUInteger len = [packet length];
  NSUInteger pos;

  if (len < NMD_RTP_HEADER_LENGTH + 1)
    {
      if (error) *error = NMDRTPError(@"RTP packet too short");
      return NO;
    }
  if ((b[0] >> 6) != 2)
    {
      if (error) *error = NMDRTPError(@"not RTP version 2");
      return NO;
    }
  pos = NMD_RTP_HEADER_LENGTH + 4u * (b[0] & 0x0F);
  if (b[0] & 0x10) /* header extension */
    {
      if (pos + 4 > len)
        {
          if (error) *error = NMDRTPError(@"RTP extension truncated");
          return NO;
        }
      pos += 4 + 4u * NMDReadBE16(b + pos + 2);
    }
  if (b[0] & 0x20) /* padding: the last byte says how much */
    {
      NSUInteger pad = b[len - 1];
      if (pad == 0 || pad > len)
        {
          if (error) *error = NMDRTPError(@"bad RTP padding");
          return NO;
        }
      len -= pad;
    }
  if (pos >= len)
    {
      if (error) *error = NMDRTPError(@"RTP packet has no payload");
      return NO;
    }
  header->payloadType = b[1] & 0x7F;
  header->sequence = NMDReadBE16(b + 2);
  header->timestamp = NMDReadBE32(b + 4);
  header->ssrc = NMDReadBE32(b + 8);
  header->hasJournal = (b[pos] & NMD_SECTION_J) != 0;
  if (offset) *offset = pos;
  return YES;
}

- (void) appendSysexBytes: (const uint8_t *)bytes length: (NSUInteger)n
{
  if (_sysexDiscarding || _sysex == nil) return;
  if ([_sysex length] + n > NMD_RTP_MIDI_MAX_SYSEX)
    {
      _sysex = nil;
      _sysexDiscarding = YES;
      return;
    }
  [_sysex appendBytes: bytes length: n];
}

- (NSArray *) messagesFromPacket: (NSData *)packet
                          header: (NMDRTPHeader *)header
                           error: (NSError **)error
{
  const uint8_t *b = [packet bytes];
  NSUInteger total = [packet length];
  NSUInteger pos, end, sectionLength;
  NSMutableArray *out = [NSMutableArray array];
  uint8_t running = 0;
  BOOL first = YES, z;

  if (![[self class] parseHeader: packet header: header payloadOffset: &pos
                           error: error])
    {
      return nil;
    }
  if (b[0] & 0x20) total -= b[total - 1];

  z = (b[pos] & NMD_SECTION_Z) != 0;
  if (b[pos] & NMD_SECTION_B)
    {
      if (pos + 2 > total)
        {
          if (error) *error = NMDRTPError(@"command section header truncated");
          return nil;
        }
      sectionLength = ((NSUInteger)(b[pos] & 0x0F) << 8) | b[pos + 1];
      pos += 2;
    }
  else
    {
      sectionLength = b[pos] & 0x0F;
      pos += 1;
    }
  end = pos + sectionLength;
  if (end > total)
    {
      if (error) *error = NMDRTPError(@"command section longer than packet");
      return nil;
    }

  /* A lost packet may have carried the middle of a sysex; what we have
   * assembled so far can no longer become a correct message. */
  if (_hasReceived && header->sequence != (uint16_t)(_lastSequence + 1))
    {
      _sequenceGaps++;
      _sysex = nil;
      _sysexDiscarding = NO;
    }
  _hasReceived = YES;
  _lastSequence = header->sequence;

  while (pos < end)
    {
      uint8_t status;

      if (!first || z)
        {
          int n = 0;
          while (pos < end && (b[pos] & 0x80))
            {
              pos++;
              if (++n >= 4) break;
            }
          if (n >= 4 || pos >= end)
            {
              if (error) *error = NMDRTPError(@"bad delta time");
              return nil;
            }
          pos++; /* last delta octet */
          if (pos >= end)
            {
              if (error) *error = NMDRTPError(@"delta time without command");
              return nil;
            }
        }
      first = NO;

      if (b[pos] & 0x80)
        {
          status = b[pos++];
        }
      else
        {
          if (running == 0)
            {
              if (error) *error = NMDRTPError(@"data byte without status");
              return nil;
            }
          status = running;
        }

      if (status == 0xF0 || status == 0xF7)
        {
          /* Sysex, whole or a segment: data bytes up to a terminator.
           * Real-time bytes may be interleaved and stand on their own. */
          uint8_t term = 0;
          NSMutableData *chunk = [NSMutableData data];

          while (pos < end)
            {
              uint8_t c = b[pos++];
              if (c < 0x80)
                {
                  [chunk appendBytes: &c length: 1];
                  continue;
                }
              if (c >= 0xF8)
                {
                  [out addObject: [NSData dataWithBytes: &c length: 1]];
                  continue;
                }
              term = c;
              break;
            }
          if (term != 0xF7 && term != 0xF5 && term != 0xF0 && term != 0xF4)
            {
              if (error) *error = NMDRTPError(@"unterminated sysex segment");
              return nil;
            }
          if (status == 0xF0)
            {
              /* A new sysex start drops any unfinished one. */
              static const uint8_t f0 = 0xF0;
              _sysex = [NSMutableData dataWithBytes: &f0 length: 1];
              _sysexDiscarding = NO;
            }
          [self appendSysexBytes: [chunk bytes] length: [chunk length]];
          /* F5 ends a sysex whose F7 the sender's source had dropped. */
          if (term == 0xF7 || term == 0xF5)
            {
              if (_sysex != nil)
                {
                  static const uint8_t f7 = 0xF7;
                  [_sysex appendBytes: &f7 length: 1];
                  [out addObject: [_sysex copy]];
                }
              _sysex = nil;
              _sysexDiscarding = NO;
            }
          else if (term == 0xF4)
            {
              _sysex = nil; /* cancelled by the sender */
              _sysexDiscarding = NO;
            }
          running = 0;
          continue;
        }

      {
        int dl = NMDDataLength(status);
        uint8_t msg[3];
        int i;

        if (dl < 0)
          {
            if (error) *error = NMDRTPError(@"undefined MIDI status");
            return nil;
          }
        if (pos + (NSUInteger)dl > end)
          {
            if (error) *error = NMDRTPError(@"MIDI command truncated");
            return nil;
          }
        msg[0] = status;
        for (i = 0; i < dl; i++)
          {
            if (b[pos] & 0x80)
              {
                if (error) *error = NMDRTPError(@"status byte inside command");
                return nil;
              }
            msg[i + 1] = b[pos++];
          }
        [out addObject: [NSData dataWithBytes: msg length: (NSUInteger)dl + 1]];
        if (status < 0xF0)
          running = status;
        else if (status < 0xF8)
          running = 0; /* system common cancels running status */
      }
    }

  if (header->hasJournal)
    {
      /* The journal is the rest of the packet.  It only helps a receiver
       * that wants to repair losses, which we do not; its length is
       * checked so a broken packet still shows up in the counters. */
      if (NMDRTPMIDIJournalLength(b + end, total - end) >= 0)
        _journalsSkipped++;
    }
  return out;
}

@end
