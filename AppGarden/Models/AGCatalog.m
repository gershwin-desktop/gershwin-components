/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGCatalog.h"
#import "AGApp.h"
#import "AGCategoryNames.h"

@implementation AGCatalog
{
  NSDictionary *_appsByName;
}

- (instancetype)initWithApps:(NSArray<AGApp *> *)apps fetchDate:(NSDate *)fetchDate
{
  self = [super init];
  if (self == nil)
    return nil;

  NSMutableArray *sorted = [NSMutableArray array];
  AGApp *app;
  for (app in apps)
    [sorted addObject:app];

  // Case-insensitive so an application whose name is written in capitals
  // does not collect at the front of the list.
  [sorted sortUsingComparator:^NSComparisonResult(AGApp *left, AGApp *right) {
    NSComparisonResult result = [[left displayName] localizedCaseInsensitiveCompare:[right displayName]];
    if (result == NSOrderedSame)
      result = [[left name] compare:[right name]];
    return result;
  }];
  _apps = [sorted copy];
  _fetchDate = (fetchDate != nil) ? fetchDate : [NSDate date];

  NSMutableArray *categories = [NSMutableArray array];
  NSMutableSet *seenCategories = [NSMutableSet set];
  for (app in _apps)
    {
      NSString *category;
      for (category in [app categories])
        {
          if ([seenCategories containsObject:category])
            continue;
          [seenCategories addObject:category];
          [categories addObject:category];
        }
    }
  _categories = [AGCategoryNames sortedRawCategories:categories];

  NSMutableDictionary *byName = [NSMutableDictionary dictionary];
  for (app in _apps)
    {
      NSString *key = [app name];
      if (key != nil && [byName objectForKey:key] == nil)
        [byName setObject:app forKey:key];
    }
  _appsByName = byName;

  return self;
}

- (AGApp *)appNamed:(NSString *)name
{
  if (name == nil)
    return nil;
  return [_appsByName objectForKey:name];
}

- (NSArray<AGApp *> *)appsInCategory:(NSString *)category
{
  if (category == nil)
    return [NSArray array];

  NSString *wantedDisplay = [AGCategoryNames displayNameForCategory:category];
  NSMutableArray *matches = [NSMutableArray array];
  AGApp *app;
  for (app in _apps)
    {
      NSString *raw;
      for (raw in [app categories])
        {
          if ([raw isEqualToString:category])
            {
              [matches addObject:app];
              break;
            }
          if ([wantedDisplay isEqualToString:[AGCategoryNames displayNameForCategory:raw]])
            {
              [matches addObject:app];
              break;
            }
        }
    }
  return matches;
}

@end
