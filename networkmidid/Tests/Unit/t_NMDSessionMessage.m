/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_NMDSessionMessage - session protocol packets, byte for byte.  The
 * vectors marked "capture" were recorded from rtpmidid on loopback
 * (runs/midi/networkmidid/peer/probe.py). */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "NMDSessionMessage.h"
#import "NMDTestHex.h"

static NSString * const kPeerName = @"rtpmidid-peer";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSError *err = nil;
  NMDSessionMessage *m;

  /* capture: our IN as rtpmidid logged it */
  m = [NMDSessionMessage messageWithCommand: NMDSessionCommandInvitation
                                     token: 0x11223344 ssrc: 0xAABBCCDD
                                      name: @"probe"];
  PASS_EQUAL(NMDHexString([m encodedData]),
    @"ffff494e0000000211223344aabbccdd70726f626500",
    "IN encodes signature, version 2, token, SSRC and NUL-terminated name");

  /* capture: rtpmidid's OK on the control port */
  m = [NMDSessionMessage messageWithData:
    NMDHex("ffff4f4b000000021122334400001f657274706d696469642d7065657200")
                                  error: &err];
  PASS(m != nil && m.command == NMDSessionCommandAccept, "OK decodes");
  PASS(m.version == 2 && m.token == 0x11223344 && m.ssrc == 0x1f65,
    "OK carries version, echoed token and the peer's SSRC");
  PASS_EQUAL(m.name, kPeerName, "OK carries the peer's name");

  /* capture: rtpmidid's CK1 answering our CK0 with timestamp1 = 1000 */
  m = [NMDSessionMessage messageWithData:
    NMDHex("ffff434b00001f650100000000000000000003e8"
          "00000000000000020000000000000000") error: &err];
  PASS(m != nil && m.command == NMDSessionCommandClockSync && m.count == 1,
    "CK1 decodes with count 1");
  PASS(m.ssrc == 0x1f65 && m.timestamp1 == 1000 && m.timestamp2 == 2
    && m.timestamp3 == 0, "CK1 echoes timestamp1 and adds timestamp2");

  m = [NMDSessionMessage clockSyncWithSSRC: 0xAABBCCDD count: 2
                               timestamp1: 1000 timestamp2: 2 timestamp3: 1010];
  PASS_EQUAL(NMDHexString([m encodedData]),
    @"ffff434baabbccdd0200000000000000000003e8"
    @"000000000000000200000000000003f2",
    "CK2 encodes count, three padding bytes and three 64-bit stamps");

  m = [NMDSessionMessage feedbackWithSSRC: 0xAABBCCDD sequence: 0x1234];
  PASS_EQUAL(NMDHexString([m encodedData]), @"ffff5253aabbccdd12340000",
    "RS puts the sequence number in the upper half of the 32-bit field");
  m = [NMDSessionMessage messageWithData: NMDHex("ffff5253aabbccdd12340000")
                                  error: &err];
  PASS(m.command == NMDSessionCommandFeedback && m.feedbackSequence == 0x1234
    && m.ssrc == 0xAABBCCDD, "RS decodes");

  m = [NMDSessionMessage messageWithCommand: NMDSessionCommandEnd
                                     token: 0x11223344 ssrc: 0xAABBCCDD
                                      name: @"ignored"];
  PASS_EQUAL(NMDHexString([m encodedData]),
    @"ffff42590000000211223344aabbccdd", "BY carries no name");

  m = [NMDSessionMessage messageWithData:
    NMDHex("ffff4e4f0000000211223344aabbccdd") error: &err];
  PASS(m.command == NMDSessionCommandReject && m.name == nil,
    "NO without name decodes");

  m = [NMDSessionMessage messageWithData:
    NMDHex("ffff494e0000000211223344aabbccdd6162") error: &err];
  PASS_EQUAL(m.name, @"ab", "a name running to the end of the datagram is kept");

  err = nil;
  m = [NMDSessionMessage messageWithData: NMDHex("ffff494e00000002112233")
                                  error: &err];
  PASS(m == nil && err != nil, "truncated IN is rejected with an error");
  m = [NMDSessionMessage messageWithData: NMDHex("ffff434b00001f6501") error: &err];
  PASS(m == nil, "truncated CK is rejected");
  m = [NMDSessionMessage messageWithData:
    NMDHex("ffff434b00001f650300000000000000000003e8"
          "00000000000000020000000000000000") error: &err];
  PASS(m == nil, "CK with count 3 is rejected");
  m = [NMDSessionMessage messageWithData: NMDHex("ffff58580000000211223344aabbccdd")
                                  error: &err];
  PASS(m == nil, "unknown command is rejected");
  PASS(![NMDSessionMessage isSessionPacket: NMDHex("80610001")],
    "an RTP packet is not a session packet");

  [arp release];
  return 0;
}
