/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGDiscoverOrder.h"

@implementation AGDiscoverOrder

+ (NSArray *)shuffled:(NSArray *)apps
{
  NSUInteger count = [apps count];
  /* Nothing to permute, and nil in must not become nil out: the caller
     hands the result straight to a page. */
  if (count < 2)
    return (apps != nil) ? [apps copy] : @[];

  NSMutableArray *shuffled = [apps mutableCopy];
  /* Fisher-Yates walking down from the top: every slot is filled from the
     range that has not been dealt with yet, which makes each of the count!
     orders equally likely. A sort by a random key would not, and
     arc4random_uniform needs no seeding. */
  for (NSUInteger i = count; i > 1; i--)
    {
      /* i is at least 2 here, and a catalog never has more entries than
         a uint32 can hold, so the draw stays in range. */
      NSUInteger j = (NSUInteger)arc4random_uniform((uint32_t)i);
      [shuffled exchangeObjectAtIndex:(i - 1) withObjectAtIndex:j];
    }
  return shuffled;
}

@end
