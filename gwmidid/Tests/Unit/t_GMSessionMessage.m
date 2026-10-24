/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_GMSessionMessage - session protocol packets, byte for byte.  The
 * vectors marked "capture" were recorded from rtpmidid on loopback
 * (runs/midi/gwmidid/peer/probe.py). */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GMSessionMessage.h"
#import "GMTestHex.h"

static NSString * const kPeerName = @"rtpmidid-peer";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSError *err = nil;
  GMSessionMessage *m;

  /* capture: our IN as rtpmidid logged it */
  m = [GMSessionMessage messageWithCommand: GMSessionCommandInvitation
                                     token: 0x11223344 ssrc: 0xAABBCCDD
                                      name: @"probe"];
  PASS_EQUAL(GMHexString([m encodedData]),
    @"ffff494e0000000211223344aabbccdd70726f626500",
    "IN encodes signature, version 2, token, SSRC and NUL-terminated name");

  /* capture: rtpmidid's OK on the control port */
  m = [GMSessionMessage messageWithData:
    GMHex("ffff4f4b000000021122334400001f657274706d696469642d7065657200")
                                  error: &err];
  PASS(m != nil && m.command == GMSessionCommandAccept, "OK decodes");
  PASS(m.version == 2 && m.token == 0x11223344 && m.ssrc == 0x1f65,
    "OK carries version, echoed token and the peer's SSRC");
  PASS_EQUAL(m.name, kPeerName, "OK carries the peer's name");

  /* capture: rtpmidid's CK1 answering our CK0 with timestamp1 = 1000 */
  m = [GMSessionMessage messageWithData:
    GMHex("ffff434b00001f650100000000000000000003e8"
          "00000000000000020000000000000000") error: &err];
  PASS(m != nil && m.command == GMSessionCommandClockSync && m.count == 1,
    "CK1 decodes with count 1");
  PASS(m.ssrc == 0x1f65 && m.timestamp1 == 1000 && m.timestamp2 == 2
    && m.timestamp3 == 0, "CK1 echoes timestamp1 and adds timestamp2");

  m = [GMSessionMessage clockSyncWithSSRC: 0xAABBCCDD count: 2
                               timestamp1: 1000 timestamp2: 2 timestamp3: 1010];
  PASS_EQUAL(GMHexString([m encodedData]),
    @"ffff434baabbccdd0200000000000000000003e8"
    @"000000000000000200000000000003f2",
    "CK2 encodes count, three padding bytes and three 64-bit stamps");

  m = [GMSessionMessage feedbackWithSSRC: 0xAABBCCDD sequence: 0x1234];
  PASS_EQUAL(GMHexString([m encodedData]), @"ffff5253aabbccdd12340000",
    "RS puts the sequence number in the upper half of the 32-bit field");
  m = [GMSessionMessage messageWithData: GMHex("ffff5253aabbccdd12340000")
                                  error: &err];
  PASS(m.command == GMSessionCommandFeedback && m.feedbackSequence == 0x1234
    && m.ssrc == 0xAABBCCDD, "RS decodes");

  m = [GMSessionMessage messageWithCommand: GMSessionCommandEnd
                                     token: 0x11223344 ssrc: 0xAABBCCDD
                                      name: @"ignored"];
  PASS_EQUAL(GMHexString([m encodedData]),
    @"ffff42590000000211223344aabbccdd", "BY carries no name");

  m = [GMSessionMessage messageWithData:
    GMHex("ffff4e4f0000000211223344aabbccdd") error: &err];
  PASS(m.command == GMSessionCommandReject && m.name == nil,
    "NO without name decodes");

  m = [GMSessionMessage messageWithData:
    GMHex("ffff494e0000000211223344aabbccdd6162") error: &err];
  PASS_EQUAL(m.name, @"ab", "a name running to the end of the datagram is kept");

  err = nil;
  m = [GMSessionMessage messageWithData: GMHex("ffff494e00000002112233")
                                  error: &err];
  PASS(m == nil && err != nil, "truncated IN is rejected with an error");
  m = [GMSessionMessage messageWithData: GMHex("ffff434b00001f6501") error: &err];
  PASS(m == nil, "truncated CK is rejected");
  m = [GMSessionMessage messageWithData:
    GMHex("ffff434b00001f650300000000000000000003e8"
          "00000000000000020000000000000000") error: &err];
  PASS(m == nil, "CK with count 3 is rejected");
  m = [GMSessionMessage messageWithData: GMHex("ffff58580000000211223344aabbccdd")
                                  error: &err];
  PASS(m == nil, "unknown command is rejected");
  PASS(![GMSessionMessage isSessionPacket: GMHex("80610001")],
    "an RTP packet is not a session packet");

  [arp release];
  return 0;
}
