/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGFeedParser.h"
#import "AGError.h"
#import "AGApp.h"
#import "AGCatalog.h"

NSString * const AGErrorDomain = @"io.github.gershwin-desktop.AppGarden.AGErrorDomain";

static AGCatalog *AGCatalogFailure(NSError **error, AGErrorCode code, NSString *description)
{
  if (error != NULL)
    {
      *error = [NSError errorWithDomain:AGErrorDomain
                                   code:code
                               userInfo:@{NSLocalizedDescriptionKey: description}];
    }
  return nil;
}

@implementation AGFeedParser

+ (AGCatalog *)catalogFromData:(NSData *)data fetchDate:(NSDate *)date error:(NSError **)error
{
  if (error != NULL)
    *error = nil;

  if ([data length] == 0)
    return AGCatalogFailure(error, AGErrorNotJSON,
                            NSLocalizedString(@"The catalog is not valid JSON.", @""));

  id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if (document == nil)
    return AGCatalogFailure(error, AGErrorNotJSON,
                            NSLocalizedString(@"The catalog is not valid JSON.", @""));

  if (![document isKindOfClass:[NSDictionary class]])
    return AGCatalogFailure(error, AGErrorTopLevelNotDictionary,
                            NSLocalizedString(@"The catalog is not a JSON object.", @""));

  id items = [(NSDictionary *)document objectForKey:@"items"];
  if (items == nil)
    return AGCatalogFailure(error, AGErrorItemsMissing,
                            NSLocalizedString(@"The catalog has no \"items\" list.", @""));
  if (![items isKindOfClass:[NSArray class]])
    return AGCatalogFailure(error, AGErrorItemsNotArray,
                            NSLocalizedString(@"The catalog's \"items\" entry is not a list.", @""));

  NSMutableArray *apps = [NSMutableArray arrayWithCapacity:[(NSArray *)items count]];
  NSUInteger skipped = 0;
  id entry;
  for (entry in (NSArray *)items)
    {
      AGApp *app = [[AGApp alloc] initWithFeedItem:entry];
      if (app == nil)
        {
          skipped++;
          continue;
        }
      [apps addObject:app];
    }

  // One line per feed: the site's generator occasionally emits junk, and a
  // per-item warning would drown the log without telling the user more.
  if (skipped > 0)
    NSLog(@"AGFeedParser: skipped %lu malformed items in the catalog",
          (unsigned long)skipped);

  return [[AGCatalog alloc] initWithApps:apps fetchDate:date];
}

@end
