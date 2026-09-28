/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGAuthor.h"

@implementation AGAuthor

- (instancetype)initWithName:(NSString *)name url:(NSURL *)url
{
  self = [super init];
  if (self != nil)
    {
      _name = [name copy];
      _url = url;
    }
  return self;
}

- (instancetype)initWithFeedAuthor:(NSDictionary *)entry
{
  NSString *name = nil;
  NSURL *url = nil;

  if ([entry isKindOfClass:[NSDictionary class]])
    {
      id nameValue = [entry objectForKey:@"name"];
      if ([nameValue isKindOfClass:[NSString class]] && [(NSString *)nameValue length] > 0)
        name = nameValue;

      id urlValue = [entry objectForKey:@"url"];
      if ([urlValue isKindOfClass:[NSString class]] && [(NSString *)urlValue length] > 0)
        {
          NSURL *candidate = [NSURL URLWithString:(NSString *)urlValue];
          NSString *scheme = [[candidate scheme] lowercaseString];
          if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
            url = candidate;
        }
    }

  if (name == nil)
    return nil;
  return [self initWithName:name url:url];
}

@end
