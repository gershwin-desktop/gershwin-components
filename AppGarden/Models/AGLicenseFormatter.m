/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGLicenseFormatter.h"

static NSString *AGLicenseBaseString(NSString *raw)
{
  NSRange separator = [raw rangeOfString:@"="];
  if (separator.location == NSNotFound)
    return raw;
  return [raw substringToIndex:separator.location];
}

@implementation AGLicenseFormatter

+ (NSString *)displayStringForLicense:(NSString *)raw
{
  if (raw == nil || [raw isEqualToString:@"NOASSERTION"])
    return NSLocalizedString(@"Unknown license", @"");

  if ([AGLicenseBaseString(raw) isEqualToString:@"LicenseRef-proprietary"])
    return NSLocalizedString(@"Proprietary", @"");

  if ([raw isEqualToString:@"GPL-3.0+"] || [raw isEqualToString:@"GPL-3.0-or-later"])
    return NSLocalizedString(@"GPL-3.0 or later", @"");

  return raw;
}

+ (BOOL)isUnknownLicense:(NSString *)raw
{
  NSString *trimmed = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return ([trimmed length] == 0 || [trimmed caseInsensitiveCompare:@"NOASSERTION"] == NSOrderedSame);
}

+ (NSURL *)licenseURLForLicense:(NSString *)raw
{
  if (raw == nil || ![raw hasPrefix:@"LicenseRef-"])
    return nil;

  NSRange separator = [raw rangeOfString:@"="];
  if (separator.location == NSNotFound || separator.location + 1 >= [raw length])
    return nil;

  NSString *URLString = [raw substringFromIndex:separator.location + 1];
  NSURL *URL = [NSURL URLWithString:URLString];
  NSString *scheme = [[URL scheme] lowercaseString];
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
    return nil;
  return URL;
}

@end
