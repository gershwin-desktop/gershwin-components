/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../TXTRecordFormatter.m"

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSData *v = [@"bar" dataUsingEncoding: NSUTF8StringEncoding];
  unsigned char bin[] = { 0xff, 0xfe };
  NSData *b = [NSData dataWithBytes: bin length: 2];

  PASS_EQUAL([TXTRecordFormatter linesForTXTDictionary:
    [NSDictionary dictionaryWithObject: [NSNull null] forKey: @"flag"]],
    @"  flag\n", "key without a value is shown as key only");
  PASS_EQUAL([TXTRecordFormatter linesForTXTDictionary:
    [NSDictionary dictionaryWithObject: v forKey: @"foo"]],
    @"  foo: bar\n", "data value is shown as UTF-8 text");
  PASS_EQUAL([TXTRecordFormatter linesForTXTDictionary:
    [NSDictionary dictionaryWithObject: b forKey: @"bin"]],
    @"  bin: <binary: 2 bytes>\n", "non-UTF-8 value shows a byte count");
  NSDictionary *mixed = [NSDictionary dictionaryWithObjectsAndKeys:
    v, @"b", [NSNull null], @"a", nil];
  PASS_EQUAL([TXTRecordFormatter linesForTXTDictionary: mixed],
    @"  a\n  b: bar\n", "mixed entries are sorted by key");
  PASS([TXTRecordFormatter linesForTXTDictionary:
    [NSDictionary dictionary]] == nil, "empty dictionary yields nil");
  PASS([TXTRecordFormatter linesForTXTDictionary:
    [NSDictionary dictionaryWithObject: [NSNull null] forKey: @""]] == nil,
    "empty TXT record (empty key) yields nil");
  PASS([TXTRecordFormatter linesForTXTDictionary: nil] == nil,
    "nil dictionary yields nil");
  PASS([TXTRecordFormatter stringForValue: [NSNull null]] == nil,
    "NSNull value yields nil");
  [pool release];
  return 0;
}
