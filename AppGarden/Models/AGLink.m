/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGLink.h"

static NSRegularExpression *AGRepositoryPathExpression = nil;
static NSRegularExpression *AGReleasesPathExpression = nil;

// A path-shaped value is a repository, so it is opened on the hosting site;
// anything else has to be an address we could hand to a browser.
static NSURL *AGResolvedURL(NSString *value)
{
  if ([value length] == 0)
    return nil;

  NSString *repoPath = [AGLink repoPathInURLString:value];
  if (repoPath != nil)
    return [NSURL URLWithString:[@"https://github.com/" stringByAppendingString:repoPath]];

  NSURL *candidate = [NSURL URLWithString:value];
  NSString *scheme = [[candidate scheme] lowercaseString];
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
    return nil;
  return candidate;
}

@implementation AGLink

+ (void)initialize
{
  if (self != [AGLink class])
    return;

  AGRepositoryPathExpression =
    [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
                                              options:0
                                                error:NULL];
  AGReleasesPathExpression =
    [NSRegularExpression regularExpressionWithPattern:@"^https://github\\.com/([^/]+)/([^/]+)/releases/?$"
                                              options:0
                                                error:NULL];
}

- (instancetype)initWithType:(NSString *)type URLString:(NSString *)URLString
{
  self = [super init];
  if (self != nil)
    {
      _type = [type copy];
      _URLString = [URLString copy];
      _url = AGResolvedURL(_URLString);
    }
  return self;
}

+ (NSString *)repoPathInURLString:(NSString *)string
{
  if (![string isKindOfClass:[NSString class]] || [string length] == 0)
    return nil;
  NSUInteger found = [AGRepositoryPathExpression numberOfMatchesInString:string
                                                                 options:0
                                                                   range:NSMakeRange(0, [string length])];
  return (found > 0) ? string : nil;
}

+ (NSString *)releaseRepoPathInURLString:(NSString *)string
{
  if (![string isKindOfClass:[NSString class]] || [string length] == 0)
    return nil;

  NSTextCheckingResult *match =
    [AGReleasesPathExpression firstMatchInString:string
                                          options:0
                                            range:NSMakeRange(0, [string length])];
  if (match == nil || [match numberOfRanges] < 3)
    return nil;

  NSRange ownerRange = [match rangeAtIndex:1];
  NSRange repoRange = [match rangeAtIndex:2];
  if (ownerRange.location == NSNotFound || repoRange.location == NSNotFound)
    return nil;

  return [NSString stringWithFormat:@"%@/%@",
                                    [string substringWithRange:ownerRange],
                                    [string substringWithRange:repoRange]];
}

@end
