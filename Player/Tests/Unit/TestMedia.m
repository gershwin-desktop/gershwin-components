/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TestMedia.h"
#include <unistd.h>

static void put32(NSMutableData *d, uint32_t v)
{
  uint8_t b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff };
  [d appendBytes: b length: 4];
}

static void put16(NSMutableData *d, uint16_t v)
{
  uint8_t b[2] = { v & 0xff, (v >> 8) & 0xff };
  [d appendBytes: b length: 2];
}

NSString *TestMediaWriteSilentWAV(NSString *tag, NSTimeInterval seconds)
{
  const uint32_t rate = 8000;
  uint32_t dataBytes = (uint32_t)(seconds * rate) * 2;
  NSMutableData *d = [NSMutableData data];

  /* RIFF header, little endian as the format demands */
  [d appendBytes: "RIFF" length: 4];
  put32(d, 36 + dataBytes);
  [d appendBytes: "WAVEfmt " length: 8];
  put32(d, 16);
  put16(d, 1);            /* PCM */
  put16(d, 1);            /* mono */
  put32(d, rate);
  put32(d, rate * 2);
  put16(d, 2);
  put16(d, 16);
  [d appendBytes: "data" length: 4];
  put32(d, dataBytes);
  [d increaseLengthBy: dataBytes];

  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"player-%@-%d.wav", tag, (int)getpid()]];
  [d writeToFile: path atomically: YES];
  return path;
}
