/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ServiceTypeName.h"

@implementation ServiceTypeName

+ (NSString *)protocolForLabel:(NSString *)label
{
  /* The label may be followed by the domain, depending on the backend */
  NSString *first = [[label componentsSeparatedByString: @"."] objectAtIndex: 0];

  if ([first isEqualToString: @"_tcp"])
    {
      return @"tcp";
    }
  if ([first isEqualToString: @"_udp"])
    {
      return @"udp";
    }
  return nil;
}

+ (NSString *)fullTypeForName:(NSString *)name protocolLabel:(NSString *)label
{
  NSString *protocol = [self protocolForLabel: label];

  if ([name length] == 0 || protocol == nil)
    {
      return nil;
    }
  return [NSString stringWithFormat: @"%@._%@", name, protocol];
}

+ (NSString *)titleForName:(NSString *)name protocolLabel:(NSString *)label
{
  NSString *protocol = [self protocolForLabel: label];

  if ([name length] == 0 || protocol == nil)
    {
      return nil;
    }
  return [NSString stringWithFormat: @"%@ (%@)", name,
                   [protocol uppercaseString]];
}

+ (BOOL)typeCanOpenInBrowser:(NSString *)fullType
{
  /* Matches "_x._tcp" with or without the trailing dot / domain */
  return fullType != nil
    && [fullType rangeOfString: @"._tcp"].location != NSNotFound;
}

@end
