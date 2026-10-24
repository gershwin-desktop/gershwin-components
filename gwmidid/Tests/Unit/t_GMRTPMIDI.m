/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_GMRTPMIDI - RTP MIDI payload (RFC 6295) encoding and decoding. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GMRTPMIDI.h"
#import "GMTestHex.h"

static NSArray *Decode(GMRTPMIDIDecoder *d, const char *hex, NSError **err)
{
  GMRTPHeader h;
  return [d messagesFromPacket: GMHex(hex) header: &h error: err];
}

static NSString *Joined(NSArray *msgs)
{
  NSMutableArray *a = [NSMutableArray array];
  for (NSData *m in msgs) [a addObject: GMHexString(m)];
  return [a componentsJoinedByString: @" "];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSError *err = nil;
  NSArray *pk, *msgs;
  GMRTPMIDIEncoder *enc;
  GMRTPMIDIDecoder *dec;

  START_SET("encoder")
    enc = [[[GMRTPMIDIEncoder alloc] initWithSSRC: 0xAABBCCDD sequence: 1]
      autorelease];
    pk = [enc packetsForMessages: @[GMHex("903c64")] timestamp: 123];
    PASS([pk count] == 1, "one note on is one packet");
    PASS_EQUAL(GMHexString([pk objectAtIndex: 0]),
      @"80610001" @"0000007b" @"aabbccdd" @"03903c64",
      "note on: RTP header, short command section header, no delta time");
    PASS([enc nextSequence] == 2, "sequence number advances per packet");

    pk = [enc packetsForMessages: @[GMHex("903c64"), GMHex("903e64"),
      GMHex("803c00")] timestamp: 0];
    PASS_EQUAL(GMHexString([pk objectAtIndex: 0]),
      @"80610002" @"00000000" @"aabbccdd" @"0a903c6400" @"3e6400803c00",
      "running status drops the repeated 0x90; each later command has delta 0");

    enc.usesRunningStatus = NO;
    pk = [enc packetsForMessages: @[GMHex("903c64"), GMHex("903e64")]
                       timestamp: 0];
    PASS_EQUAL(GMHexString([pk objectAtIndex: 0]),
      @"80610003" @"00000000" @"aabbccdd" @"07903c6400903e64",
      "without running status every status byte is sent");
    enc.usesRunningStatus = YES;

    pk = [enc packetsForMessages: @[GMHex("b0077f"), GMHex("e00040"),
      GMHex("c005"), GMHex("f8"), GMHex("c006"), GMHex("b00a40")] timestamp: 0];
    PASS_EQUAL(GMHexString([pk objectAtIndex: 0]),
      @"80610004" @"00000000" @"aabbccdd"
      @"8012" @"b0077f00e0004000c00500f8000600b00a40",
      "CC, pitch bend, program change; real-time keeps running status; "
      "an 18-byte list uses the two-byte header");

    pk = [enc packetsForMessages: @[GMHex("f00102030405060708f7")] timestamp: 0];
    PASS_EQUAL(GMHexString([pk objectAtIndex: 0]),
      @"80610005" @"00000000" @"aabbccdd" @"0af00102030405060708f7",
      "a short sysex goes out whole");

    {
      NSMutableData *big = [NSMutableData data];
      uint8_t b = 0xF0;
      int i;
      NSMutableArray *all = [NSMutableArray array];
      GMRTPMIDIDecoder *d2 = [[GMRTPMIDIDecoder new] autorelease];
      const uint8_t *p0, *p1;
      NSUInteger l0;

      [big appendBytes: &b length: 1];
      for (i = 0; i < 300; i++) { b = (uint8_t)(i & 0x7F); [big appendBytes: &b length: 1]; }
      b = 0xF7;
      [big appendBytes: &b length: 1];
      enc.maxCommandSectionLength = 100;
      pk = [enc packetsForMessages: @[GMHex("903c64"), big, GMHex("803c00")]
                         timestamp: 0];
      PASS([pk count] == 4, "302-byte sysex in 100-byte sections takes 4 packets");
      p0 = [[pk objectAtIndex: 0] bytes];
      l0 = [[pk objectAtIndex: 0] length];
      p1 = [[pk objectAtIndex: 1] bytes];
      PASS(l0 == 12 + 2 + 100, "first packet is filled up to the limit");
      PASS(p0[14] == 0x90 && p0[17] == 0x00 && p0[18] == 0xF0
        && p0[l0 - 1] == 0xF0, "first segment starts F0 and ends F0");
      PASS(p1[14] == 0xF7 && p1[[[pk objectAtIndex: 1] length] - 1] == 0xF0,
        "middle segment starts F7 and ends F0");
      for (NSData *p in pk)
        {
          GMRTPHeader h;
          NSArray *m = [d2 messagesFromPacket: p header: &h error: &err];
          if (m) [all addObjectsFromArray: m];
        }
      PASS([all count] == 3, "decoder yields note on, the sysex, note off");
      PASS([[all objectAtIndex: 1] isEqual: big], "sysex reassembles byte-exact");
      PASS_EQUAL(GMHexString([all objectAtIndex: 2]), @"803c00",
        "a command after the last segment still decodes");
    }
  END_SET("encoder")

  START_SET("decoder")
    dec = [[GMRTPMIDIDecoder new] autorelease];

    /* RFC 6295 Figure 6, "a two-segment segmentation", in two packets */
    msgs = Decode(dec, "80610010 00000000 aabbccdd 06 f001020304f0", &err);
    PASS(msgs != nil && [msgs count] == 0, "first segment alone yields nothing");
    msgs = Decode(dec, "80610011 00000000 aabbccdd 06 f705060708f7", &err);
    PASS_EQUAL(Joined(msgs), @"f00102030405060708f7",
      "RFC 6295 Figure 6 two-segment sysex reassembles");

    /* RFC 6295 Figure 6, "a three-segment segmentation", in one packet */
    msgs = Decode(dec, "80610012 00000000 aabbccdd 8010 f00102f000f70304f000f705060708f7",
      &err);
    PASS_EQUAL(Joined(msgs), @"f00102030405060708f7",
      "RFC 6295 Figure 6 three-segment sysex reassembles");

    msgs = Decode(dec, "80610013 00000000 aabbccdd 0b f00102f000f70304f4 00 f8", &err);
    PASS_EQUAL(Joined(msgs), @"f8", "a cancelled sysex (F7 ... F4) is dropped");

    msgs = Decode(dec, "80610014 00000000 aabbccdd 07 f00102f80304f5", &err);
    PASS_EQUAL(Joined(msgs), @"f8 f001020304f7",
      "real-time inside a sysex comes out first; F5 ends a sysex like F7");

    msgs = Decode(dec, "80610015 00000000 aabbccdd 2d 8100 903c64 8180 00 3e64 00 c005",
      &err);
    PASS_EQUAL(Joined(msgs), @"903c64 903e64 c005",
      "Z flag: first command has a delta; multi-octet deltas; running status");

    msgs = Decode(dec, "80610016 00000000 aabbccdd 07 903c64 00 f6 00 3c", &err);
    PASS(msgs == nil, "data byte after system common (no running status) is an error");

    msgs = Decode(dec, "80610017 00000000 aabbccdd 02 3c64", &err);
    PASS(msgs == nil, "first command without status is an error");

    msgs = Decode(dec, "80610018 00000000 aabbccdd 05 903c", &err);
    PASS(msgs == nil, "section longer than the packet is an error");

    msgs = Decode(dec, "80610019 00000000 aabbccdd 02 903c", &err);
    PASS(msgs == nil, "truncated command is an error");

    /* J flag: a journal with one channel journal (chapter N, 6 bytes)
     * follows the 3-byte list and must simply be skipped. */
    msgs = Decode(dec, "8061001a 00000000 aabbccdd 43 903c64 "
                       "20 0019 00 06 08 01 3c 64", &err);
    PASS_EQUAL(Joined(msgs), @"903c64", "commands before a journal decode");
    PASS([dec journalsSkipped] == 1, "the journal was recognised and skipped");

    msgs = Decode(dec, "8061001b 00000000 aabbccdd 43 903c64 "
                       "60 001a 0004 0000 00 05 08 3c 64", &err);
    PASS_EQUAL(Joined(msgs), @"903c64", "journal with system journal skipped");
    PASS([dec journalsSkipped] == 2, "system plus channel journal walked");

    {
    NSUInteger gaps = [dec sequenceGaps];
    msgs = Decode(dec, "8061001c 00000000 aabbccdd 06 f001020304f0", &err);
    msgs = Decode(dec, "8061001e 00000000 aabbccdd 06 f705060708f7", &err);
    PASS([dec sequenceGaps] == gaps + 1, "a skipped sequence number counts as a gap");
    PASS(msgs != nil && [msgs count] == 0,
      "a sysex whose middle may be lost is not delivered");
    }

    {
      GMRTPHeader h;
      NSUInteger off;
      PASS([GMRTPMIDIDecoder parseHeader: GMHex("80e1abcd 01020304 0a0b0c0d 00")
                                  header: &h payloadOffset: &off error: &err]
        && h.sequence == 0xabcd && h.timestamp == 0x01020304
        && h.ssrc == 0x0a0b0c0d && h.payloadType == 0x61 && off == 12,
        "RTP header fields; the marker bit is not part of the payload type");
      PASS(![GMRTPMIDIDecoder parseHeader: GMHex("40610001 00000000 aabbccdd 00")
                                   header: &h payloadOffset: &off error: &err],
        "RTP version 1 is rejected");
    }
  END_SET("decoder")

  START_SET("journal length")
    PASS(GMRTPMIDIJournalLength(GMHex("20001900060801 3c64").bytes, 9) == 9,
      "one channel journal");
    PASS(GMRTPMIDIJournalLength(GMHex("200019000a").bytes, 5) == -1,
      "a channel journal longer than the packet is malformed");
    PASS(GMRTPMIDIJournalLength(GMHex("0000").bytes, 2) == -1,
      "a journal header needs three bytes");
  END_SET("journal length")

  [arp release];
  return 0;
}
