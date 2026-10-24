/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_GMMIDIStreamParser - raw MIDI bytes from a local port to messages. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GMMIDIStreamParser.h"
#import "GMTestHex.h"

static NSString *Feed(GMMIDIStreamParser *p, const char *hex)
{
  NSData *d = GMHex(hex);
  NSMutableArray *a = [NSMutableArray array];
  for (NSData *m in [p messagesFromBytes: [d bytes] length: [d length]])
    [a addObject: GMHexString(m)];
  return [a componentsJoinedByString: @" "];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  GMMIDIStreamParser *p = [[GMMIDIStreamParser new] autorelease];

  PASS_EQUAL(Feed(p, "903c64 3e64 3e00"), @"903c64 903e64 903e00",
    "running status in the stream is expanded");
  PASS_EQUAL(Feed(p, "90"), @"", "a status byte alone is held");
  PASS_EQUAL(Feed(p, "3c"), @"", "so is a partial message");
  PASS_EQUAL(Feed(p, "64"), @"903c64", "the message completes across pieces");
  PASS_EQUAL(Feed(p, "903c f8 64"), @"f8 903c64",
    "a real-time byte inside a message comes out on its own, first");
  PASS_EQUAL(Feed(p, "c005 06 d040"), @"c005 c006 d040",
    "two-byte channel messages with running status");
  PASS_EQUAL(Feed(p, "f6 3c"), @"f6", "system common cancels running status");
  PASS_EQUAL(Feed(p, "f00102"), @"", "a sysex start is held");
  PASS_EQUAL(Feed(p, "03 fe 04"), @"fe", "active sensing inside a sysex passes");
  PASS_EQUAL(Feed(p, "05f7"), @"f00102030405f7",
    "the sysex comes out whole once F7 arrives");
  PASS_EQUAL(Feed(p, "f00102 903c64"), @"903c64",
    "a sysex cut off by a status byte is dropped; the new message is kept");
  PASS_EQUAL(Feed(p, "f1 20 f2 0102 f3 05"), @"f120 f20102 f305",
    "MTC quarter frame, song position, song select");
  PASS_EQUAL(Feed(p, "f9 fd f4 f5"), @"", "undefined codes are dropped");

  p.maxSysexLength = 8;
  PASS_EQUAL(Feed(p, "f0010203040506070809f7 803c00"), @"803c00",
    "a sysex above the limit is dropped");
  PASS(p.droppedSysex == 1, "and counted");

  [arp release];
  return 0;
}
