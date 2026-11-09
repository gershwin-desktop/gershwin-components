/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TXTRecordFormatter.h"

@implementation TXTRecordFormatter

+ (NSString *)stringForValue:(id)value
{
  if (![value isKindOfClass: [NSData class]])
    {
      return nil;
    }
  NSString *str = [[NSString alloc] initWithData: value
                                        encoding: NSUTF8StringEncoding];
  if (str == nil)
    {
      str = [[NSString alloc] initWithFormat: @"<binary: %lu bytes>",
                              (unsigned long)[value length]];
    }
  return AUTORELEASE(str);
}

+ (NSString *)linesForTXTDictionary:(NSDictionary *)dict
{
  NSMutableString *lines = [NSMutableString string];
  NSArray *keys = [[dict allKeys]
    sortedArrayUsingSelector: @selector(compare:)];
  for (NSString *key in keys)
    {
      /* An empty TXT record is one zero-length string, which libs-base
       * turns into an entry with an empty key; there is nothing to show. */
      if ([key length] == 0)
        {
          continue;
        }
      NSString *valueStr = [self stringForValue: [dict objectForKey: key]];
      if (valueStr)
        {
          [lines appendFormat: @"  %@: %@\n", key, valueStr];
        }
      else
        {
          [lines appendFormat: @"  %@\n", key];
        }
    }
  return [lines length] > 0 ? lines : nil;
}

@end
