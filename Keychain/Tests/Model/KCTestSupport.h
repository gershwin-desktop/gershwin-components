/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Known-answer vectors are written as hex, the way the RFCs print them. */
static inline NSData *KCDataFromHex(NSString *hex)
{
  NSString *clean = [[hex componentsSeparatedByCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
    componentsJoinedByString: @""];
  NSMutableData *data = [NSMutableData dataWithCapacity: [clean length] / 2];
  NSUInteger i;

  for (i = 0; i + 1 < [clean length]; i += 2)
    {
      unsigned int byte;
      NSScanner *scanner = [NSScanner scannerWithString:
        [clean substringWithRange: NSMakeRange(i, 2)]];

      [scanner scanHexInt: &byte];
      uint8_t b = (uint8_t)byte;
      [data appendBytes: &b length: 1];
    }
  return data;
}

static inline NSData *KCUTF8(NSString *s)
{
  return [s dataUsingEncoding: NSUTF8StringEncoding];
}

/* A fresh directory per run so parallel runs never share keyring files. */
static inline NSString *KCTemporaryDirectory(NSString *tag)
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"kc-test-%@-%d", tag, (int)getpid()]];

  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
                            withIntermediateDirectories: YES
                                             attributes: nil
                                                  error: NULL];
  return dir;
}
