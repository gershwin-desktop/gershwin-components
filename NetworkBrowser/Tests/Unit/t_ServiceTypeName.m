/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../ServiceTypeName.m"

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  /* The type meta browse reports the name "_kdeconnect" and the protocol
   * label "_udp." (with the trailing dot of the Avahi backend) */
  PASS_EQUAL([ServiceTypeName protocolForLabel: @"_udp."], @"udp",
    "udp label with trailing dot");
  PASS_EQUAL([ServiceTypeName protocolForLabel: @"_tcp"], @"tcp",
    "tcp label without dot");
  PASS_EQUAL([ServiceTypeName protocolForLabel: @"_udp.local."], @"udp",
    "label followed by the domain");
  PASS([ServiceTypeName protocolForLabel: @"_sctp."] == nil,
    "unknown protocol is rejected");
  PASS([ServiceTypeName protocolForLabel: nil] == nil, "nil label");

  PASS_EQUAL([ServiceTypeName fullTypeForName: @"_ssh" protocolLabel: @"_tcp."],
    @"_ssh._tcp", "tcp type string");
  PASS_EQUAL([ServiceTypeName fullTypeForName: @"_apple-midi"
                                protocolLabel: @"_udp."],
    @"_apple-midi._udp", "udp type string is not forced to tcp");
  PASS([ServiceTypeName fullTypeForName: @"" protocolLabel: @"_udp."] == nil,
    "empty name");
  PASS([ServiceTypeName fullTypeForName: @"_ssh" protocolLabel: @"_xyz."] == nil,
    "bad protocol gives no type string");

  PASS_EQUAL([ServiceTypeName titleForName: @"_apple-midi"
                             protocolLabel: @"_udp."],
    @"_apple-midi (UDP)", "title shows the protocol");
  PASS_EQUAL([ServiceTypeName titleForName: @"_http" protocolLabel: @"_tcp."],
    @"_http (TCP)", "title shows tcp");

  PASS([ServiceTypeName typeCanOpenInBrowser: @"_http._tcp."], "http tcp opens");
  PASS([ServiceTypeName typeCanOpenInBrowser: @"_https._tcp"], "https tcp opens");
  PASS(![ServiceTypeName typeCanOpenInBrowser: @"_http._udp."],
    "http over udp does not open");
  PASS(![ServiceTypeName typeCanOpenInBrowser: @"_apple-midi._udp."],
    "udp service does not open");
  PASS([ServiceTypeName typeCanOpenInBrowser: @"_sane-port._tcp."],
    "other TCP services keep the open action");
  PASS(![ServiceTypeName typeCanOpenInBrowser: nil], "nil type");

  [pool release];
  return 0;
}
