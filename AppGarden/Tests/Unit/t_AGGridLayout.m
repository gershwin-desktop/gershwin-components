/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGGridLayout.h"
#include <math.h>

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* The brief's own numbers: 200 x 232 cards, 20-point minimum gap,
   * 24-point side inset (METRICS_CONTENT_SIDE_MARGIN). */
  AGGridLayout *grid = [[AGGridLayout alloc] initWithCardSize: NSMakeSize(200, 232)
                                                  minimumGap: 20
                                                    sideInset: 24];

  /* --- how many columns fit --- */
  PASS([grid columnsForWidth: 1000] == 4,
       "1000 points hold four cards: 24+4*200+3*20+24 = 908 fits, 1128 does not");
  PASS([grid columnsForWidth: 1128] == 5,
       "exactly 1128 points hold the fifth column");
  PASS([grid columnsForWidth: 1127] == 4,
       "one point less falls back to four columns");
  PASS([grid columnsForWidth: 908] == 4,
       "the tight fit for four columns is exactly 908 points");
  PASS([grid columnsForWidth: 907] == 3,
       "one point less fits only three");
  PASS([grid columnsForWidth: 50] == 1,
       "a width below one card still yields one column");

  /* --- the extra space goes into the gaps --- */
  CGFloat gap = [grid horizontalGapForWidth: 1000];
  PASS(gap > 20, "gaps grow past the minimum to spread the cards (%.2f)", gap);
  PASS(fabs(2 * 24 + 4 * 200 + 3 * gap - 1000) < 0.01,
       "insets + cards + grown gaps fill the width exactly (%.2f)", gap);
  PASS(fabs([grid horizontalGapForWidth: 908] - 20.0) < 0.001,
       "with no slack the gap stays at the minimum");

  /* --- card frames, first row at the top --- */
  NSRect first = [grid frameForIndex: 0 width: 1000];
  PASS(fabs(first.origin.x - 24) < 0.001 && fabs(first.origin.y - 24) < 0.001,
       "the first card sits at the top-left inset (%.1f, %.1f)",
       first.origin.x, first.origin.y);
  PASS(NSEqualSizes(first.size, NSMakeSize(200, 232)),
       "a frame is exactly one card");

  NSRect sixth = [grid frameForIndex: 5 width: 1000];
  PASS(fabs(sixth.origin.x - (24 + 200 + gap)) < 0.01,
       "index 5 sits in column 1 (%.2f)", sixth.origin.x);
  PASS(fabs(sixth.origin.y - (24 + 232 + 20)) < 0.01,
       "index 5 sits in row 1 below the minimum row gap (%.2f)", sixth.origin.y);

  /* --- hit testing --- */
  PASS([grid indexAtPoint: NSMakePoint(30, 30) width: 1000 count: 8] == 0,
       "a point inside the first card hits it");
  PASS([grid indexAtPoint: NSMakePoint(250, 100) width: 1000 count: 8] == -1,
       "a point in a horizontal gap hits nothing");
  PASS([grid indexAtPoint: NSMakePoint(100, 265) width: 1000 count: 8] == -1,
       "a point in a vertical gap hits nothing");
  PASS([grid indexAtPoint: NSMakePoint(990, 100) width: 1000 count: 8] == -1,
       "a point in the right side inset hits nothing");
  PASS([grid indexAtPoint: NSMakePoint(100, 5) width: 1000 count: 8] == -1,
       "a point above the first row hits nothing");
  PASS([grid indexAtPoint: NSMakePoint(24 + 2 * (200 + gap) + 10, 286)
                   width: 1000 count: 5] == -1,
       "a card slot past the last item hits nothing");

  /* --- content height --- */
  PASS([grid heightForCount: 0 width: 1000] == 0,
       "an empty grid has zero height");
  PASS(fabs([grid heightForCount: 1 width: 1000] - 280.0) < 0.001,
       "one card is inset + card + inset");
  PASS(fabs([grid heightForCount: 5 width: 1000] - 532.0) < 0.001,
       "five cards over two rows add one minimum row gap");

  [grid release];
  [arp release];
  return 0;
}
