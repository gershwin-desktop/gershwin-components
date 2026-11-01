/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDMIDIStreamParser.h"
#import "NMDRTPMIDI.h"

@implementation NMDMIDIStreamParser
{
  uint8_t _running;       /* channel status for running status, 0 = none */
  uint8_t _message[3];
  NSUInteger _have;       /* bytes collected in _message */
  NSUInteger _need;       /* bytes the current message needs in total */
  NSMutableData *_sysex;  /* non-nil while inside a sysex */
  BOOL _discardingSysex;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _maxSysexLength = NMD_RTP_MIDI_MAX_SYSEX;
    }
  return self;
}

- (void) reset
{
  _running = 0;
  _have = _need = 0;
  _sysex = nil;
  _discardingSysex = NO;
}

static NSUInteger NMDMessageLength(uint8_t status)
{
  switch (status & 0xF0)
    {
      case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 3;
      case 0xC0: case 0xD0: return 2;
      default: break;
    }
  switch (status)
    {
      case 0xF1: case 0xF3: return 2;
      case 0xF2: return 3;
      default: return 1; /* F6, and the undefined F4/F5 are dropped */
    }
}

- (NSArray *) messagesFromBytes: (const uint8_t *)bytes length: (NSUInteger)len
{
  NSMutableArray *out = [NSMutableArray array];
  NSUInteger i;

  for (i = 0; i < len; i++)
    {
      uint8_t c = bytes[i];

      if (c >= 0xF8)
        {
          if (c != 0xF9 && c != 0xFD) /* undefined real-time codes */
            [out addObject: [NSData dataWithBytes: &c length: 1]];
          continue;
        }

      if (_sysex != nil || _discardingSysex)
        {
          if (c < 0x80)
            {
              if (!_discardingSysex)
                {
                  if ([_sysex length] + 2 > _maxSysexLength)
                    {
                      _sysex = nil;
                      _discardingSysex = YES;
                      _droppedSysex++;
                    }
                  else
                    {
                      [_sysex appendBytes: &c length: 1];
                    }
                }
              continue;
            }
          if (c == 0xF7 && !_discardingSysex)
            {
              [_sysex appendBytes: &c length: 1];
              [out addObject: [_sysex copy]];
            }
          _sysex = nil;
          _discardingSysex = NO;
          if (c == 0xF7) continue;
          /* Any other status ends the sysex unfinished; it is dropped and
           * the status byte starts a message of its own below. */
        }

      if (c == 0xF0)
        {
          _sysex = [NSMutableData dataWithBytes: &c length: 1];
          _running = 0;
          _have = _need = 0;
          continue;
        }

      if (c >= 0x80)
        {
          if (c == 0xF7 || c == 0xF4 || c == 0xF5)
            {
              _have = _need = 0;
              _running = 0;
              continue;
            }
          _message[0] = c;
          _have = 1;
          _need = NMDMessageLength(c);
          _running = (c < 0xF0) ? c : 0;
        }
      else
        {
          if (_have == 0)
            {
              if (_running == 0) continue; /* stray data byte */
              _message[0] = _running;
              _have = 1;
              _need = NMDMessageLength(_running);
            }
          _message[_have++] = c;
        }

      if (_have == _need)
        {
          [out addObject: [NSData dataWithBytes: _message length: _have]];
          _have = _need = 0;
        }
    }
  return out;
}

@end
