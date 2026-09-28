/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGFeedParser.h"
#import "AGCatalog.h"
#import "AGApp.h"
#import "AGSearchIndex.h"

static NSString *fixturePath = @"../../Fixtures/feed-sample.json";

static AGCatalog *parseFixture(void)
{
  NSData *data = [NSData dataWithContentsOfFile: fixturePath];
  NSError *error = nil;
  AGCatalog *catalog = [AGFeedParser catalogFromData: data
                                           fetchDate: [NSDate date]
                                               error: &error];
  return catalog;
}

/* A catalog the size of the live feed (1551 items), with the marker word
 * "zebrafrost" in every hundredth description so a query for it scans all
 * items but matches only a few - the per-keystroke worst case. */
static AGCatalog *syntheticCatalog(NSUInteger count)
{
  NSArray *categoryCycle = @[ @"Utility", @"Development", @"Game", @"Graphics" ];
  NSMutableArray *apps = [[NSMutableArray alloc] initWithCapacity: count];
  NSUInteger index;
  for (index = 0; index < count; index++)
    {
      NSMutableDictionary *item = [NSMutableDictionary dictionary];
      [item setObject: [NSString stringWithFormat: @"Synth_%04lu", (unsigned long)index]
               forKey: @"name"];
      NSString *marker = (index % 100 == 0) ? @" zebrafrost marker" : @"";
      [item setObject: [NSString stringWithFormat:
                          @"Synthetic row %lu of the catalog with a description long enough to look real.%@",
                          (unsigned long)index, marker]
               forKey: @"description"];
      [item setObject: [NSArray arrayWithObject:
                          [categoryCycle objectAtIndex: index % [categoryCycle count]]]
               forKey: @"categories"];
      [item setObject: [NSArray arrayWithObject:
                          [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSString stringWithFormat: @"tester%04lu", (unsigned long)index], @"name",
                            @"https://example.com/tester", @"url", nil]]
               forKey: @"authors"];
      AGApp *app = [[AGApp alloc] initWithFeedItem: item];
      [apps addObject: app];
      [app release];
    }
  AGCatalog *catalog = [[AGCatalog alloc] initWithApps: apps fetchDate: [NSDate date]];
  [apps release];
  return catalog;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  AGCatalog *catalog = parseFixture();
  PASS(catalog != nil, "fixture parses");
  AGSearchIndex *index = [[AGSearchIndex alloc] initWithCatalog: catalog];

  /* --- the queries from the brief --- */
  {
    NSArray *hits = [index appsMatchingQuery: @"netbeans" inCategory: nil];
    PASS([hits count] > 0, "a lowercase query finds Apache_NetBeans");
    PASS_EQUAL([[hits objectAtIndex: 0] displayName], @"Apache NetBeans",
               "the name match ranks first");

    hits = [index appsMatchingQuery: @"NETBEANS" inCategory: nil];
    PASS([hits count] > 0, "an uppercase query finds Apache_NetBeans too");
    PASS_EQUAL([[hits objectAtIndex: 0] displayName], @"Apache NetBeans",
               "the name match ranks first for any case");
  }
  {
    NSArray *hits = [index appsMatchingQuery: @"apk editor" inCategory: nil];
    PASS([hits count] > 0, "two terms both have to match");
    PASS_EQUAL([[hits objectAtIndex: 0] displayName], @"APK Editor Studio",
               "the app whose name carries both terms ranks first");
  }
  {
    NSArray *hits = [index appsMatchingQuery: @"wallpaper" inCategory: nil];
    BOOL found = NO;
    AGApp *app;
    for (app in hits)
      if ([[app name] isEqualToString: @"4KWALL"])
        found = YES;
    PASS(found, "a word only in the description still finds the app");
  }
  {
    NSArray *games = [index appsMatchingQuery: @"" inCategory: @"Game"];
    PASS([games count] == 2, "the Game category holds the two games (got %lu)",
         (unsigned long)[games count]);
    PASS_EQUAL([[games objectAtIndex: 0] displayName], @"Alpine Client",
               "an empty query keeps catalog order, first game first");
    PASS_EQUAL([[games objectAtIndex: 1] displayName], @"Artifact",
               "an empty query keeps catalog order, second game second");

    NSArray *all = [index appsMatchingQuery: @"   " inCategory: nil];
    PASS([all count] == 16, "a whitespace-only query over no category is everything (got %lu)",
         (unsigned long)[all count]);
  }
  {
    NSArray *hits = [index appsMatchingQuery: @"zzzz" inCategory: nil];
    PASS([hits count] == 0, "a query that matches nothing returns an empty array");
  }

  /* --- query and category intersect --- */
  {
    NSArray *hits = [index appsMatchingQuery: @"simple" inCategory: @"Utility"];
    PASS([hits count] == 1, "only one Utility app talks about simple things (got %lu)",
         (unsigned long)[hits count]);
    PASS_EQUAL([[hits objectAtIndex: 0] displayName], @"Agora",
               "the category filter narrows the query");
  }
  {
    /* The sidebar shows "Audio & Video" but the feed says "AudioVideo";
     * matching both spellings keeps a typed category word working. */
    NSArray *hits = [index appsMatchingQuery: @"audiovideo" inCategory: nil];
    PASS([hits count] == 1, "the raw category name matches too (got %lu)",
         (unsigned long)[hits count]);
    PASS_EQUAL([[hits objectAtIndex: 0] displayName], @"OVideo",
               "the AudioVideo app is found by its feed category");
  }

  /* --- 1551 items must answer inside one keystroke's budget --- */
  {
    NSDate *buildStart = [NSDate date];
    AGCatalog *big = syntheticCatalog(1551);
    NSTimeInterval buildTime = -[buildStart timeIntervalSinceNow];
    PASS([[big apps] count] == 1551, "the synthetic catalog holds 1551 apps (got %lu)",
         (unsigned long)[[big apps] count]);
    AGSearchIndex *bigIndex = [[AGSearchIndex alloc] initWithCatalog: big];

    NSDate *start = [NSDate date];
    NSArray *hits = [bigIndex appsMatchingQuery: @"zebrafrost" inCategory: nil];
    NSTimeInterval rareQuery = -[start timeIntervalSinceNow];
    PASS([hits count] == 16, "the marker word matches every hundredth app (got %lu)",
         (unsigned long)[hits count]);
    PASS(rareQuery < 0.1,
         "a full-scan query over 1551 apps answers in under 100 ms (%.2f ms)",
         rareQuery * 1000.0);
    NSLog(@"t_AGSearchIndex: rare query %.2f ms over 1551 apps, catalog built in %.0f ms",
          rareQuery * 1000.0, buildTime * 1000.0);

    start = [NSDate date];
    hits = [bigIndex appsMatchingQuery: @"a" inCategory: nil];
    NSTimeInterval commonQuery = -[start timeIntervalSinceNow];
    PASS([hits count] == 1551, "the single-letter query matches every app (got %lu)",
         (unsigned long)[hits count]);
    PASS(commonQuery < 0.1,
         "the worst-case single-letter query stays under 100 ms (%.2f ms)",
         commonQuery * 1000.0);
    NSLog(@"t_AGSearchIndex: single-letter query %.2f ms over 1551 apps",
          commonQuery * 1000.0);
    [bigIndex release];
    [big release];
  }

  [index release];
  [arp release];
  return 0;
}
