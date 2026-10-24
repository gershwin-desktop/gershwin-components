/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#include <ctype.h>

/* Test vectors are written as hex strings as tcpdump prints them; spaces
 * are ignored. */
static inline NSData *GMHex(const char *hex)
{
  NSMutableData *d = [NSMutableData data];
  int hi = -1;
  for (; *hex; hex++)
    {
      int v;
      if (isspace((unsigned char)*hex)) continue;
      v = isdigit((unsigned char)*hex) ? *hex - '0'
        : tolower((unsigned char)*hex) - 'a' + 10;
      if (hi < 0) hi = v;
      else
        {
          uint8_t b = (uint8_t)(hi << 4 | v);
          [d appendBytes: &b length: 1];
          hi = -1;
        }
    }
  return d;
}

static inline NSString *GMHexString(NSData *d)
{
  NSMutableString *s = [NSMutableString string];
  const uint8_t *b = [d bytes];
  NSUInteger i;
  for (i = 0; i < [d length]; i++) [s appendFormat: @"%02x", b[i]];
  return s;
}
