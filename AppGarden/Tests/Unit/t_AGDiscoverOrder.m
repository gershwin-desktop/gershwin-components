/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGDiscoverOrder.h"

static NSArray *MakeApps(NSUInteger count)
{
  NSMutableArray *apps = [NSMutableArray arrayWithCapacity:count];
  NSUInteger i;
  for (i = 0; i < count; i++)
    [apps addObject:[NSString stringWithFormat:@"app-%lu", (unsigned long)i]];
  return apps;
}

/* The multiset of a list, so a permutation can be told from a list that
   lost or duplicated something. */
static NSCountedSet *BagOf(NSArray *list)
{
  return [NSCountedSet setWithArray:list];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- degenerate inputs stay usable --- */

  PASS([AGDiscoverOrder shuffled: nil] != nil,
       "nil in gives an empty list out, never nil");
  PASS_EQUAL([[AGDiscoverOrder shuffled: nil] count], 0U,
             "nil in gives no entries");

  NSArray *empty = @[];
  PASS_EQUAL([[AGDiscoverOrder shuffled: empty] count], 0U,
             "an empty list stays empty");

  NSArray *one = @[@"only"];
  PASS_EQUAL([[AGDiscoverOrder shuffled: one] objectAtIndex: 0], @"only",
             "a single app has one order to be in");

  /* --- the result is a permutation of the input --- */

  NSArray *apps = MakeApps(500);
  NSArray *shuffled = [AGDiscoverOrder shuffled: apps];

  PASS_EQUAL([shuffled count], [apps count],
             "a 500 app list comes back with 500 entries");
  PASS_EQUAL(BagOf(shuffled), BagOf(apps),
             "the same 500 apps come back, each exactly once");
  PASS([shuffled isEqualToArray: apps] == NO
          || [apps count] < 2,
       "500 apps do not all come back in feed order");

  /* --- the order really is random, not one fixed rotation --- */

  /* A rotation, a reversal or a sort with a fixed key would satisfy
     everything above and still be predictable. The first entry of 40
     shuffles of a 40 entry list is therefore collected and required to
     vary; the chance of a false failure is 40 * 39^-39, which no seed
     will reach. */
  NSMutableSet *firstSeen = [NSMutableSet set];
  NSMutableSet *lastSeen = [NSMutableSet set];
  NSUInteger i;
  for (i = 0; i < 40; i++)
    {
      NSArray *once = [AGDiscoverOrder shuffled: MakeApps(40)];
      [firstSeen addObject:[once objectAtIndex: 0]];
      [lastSeen addObject:[once objectAtIndex: 39]];
    }
  PASS([firstSeen count] > 1,
       "the first app differs between shuffles (%lu distinct of 40)",
       (unsigned long)[firstSeen count]);
  PASS([lastSeen count] > 1,
       "the last app differs between shuffles (%lu distinct of 40)",
       (unsigned long)[lastSeen count]);

  /* A single swap of two entries is the smallest change a shuffle can
     make, and it is what a two element list has to do to be random. */
  BOOL swappedAtLeastOnce = NO;
  for (i = 0; i < 40; i++)
    {
      NSArray *pair = [AGDiscoverOrder shuffled: @[@"a", @"b"]];
      if (![[pair objectAtIndex: 0] isEqualToString: @"a"])
        {
          swappedAtLeastOnce = YES;
          break;
        }
    }
  PASS(swappedAtLeastOnce, "two apps swap places within 40 shuffles");

  /* --- two shuffles of the same catalog must not come back equal, or the
         user would see the same order every launch --- */
  NSArray *firstRun = [AGDiscoverOrder shuffled: apps];
  NSArray *secondRun = [AGDiscoverOrder shuffled: apps];
  PASS([firstRun isEqualToArray: secondRun] == NO,
       "two shuffles of the same 500 apps are not the same order");

  /* --- the input is not modified --- */
  NSArray *ordered = MakeApps(20);
  (void)[AGDiscoverOrder shuffled: ordered];
  BOOL unchanged = YES;
  for (i = 0; i < [ordered count]; i++)
    {
      if (![[ordered objectAtIndex: i] isEqualToString:
             [NSString stringWithFormat:@"app-%lu", (unsigned long)i]])
        unchanged = NO;
    }
  PASS(unchanged, "the caller's list is left in its own order");

  [arp release];
  return 0;
}
