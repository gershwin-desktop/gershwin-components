/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "BookshelfView.h"


int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* The document view is flipped so that it lays out from the top and the
   * scroll origin does not depend on the fractional visible height. */
  {
    BookshelfView *v = [[BookshelfView alloc]
        initWithFrame:NSMakeRect(0, 0, 400, 300)];
    PASS([v isFlipped], "bookshelf view is flipped");
  }

  /* Row 0 is at the top: smaller y than row 1, books of row 0 first. */
  {
    NSArray *r = [BookshelfView spineRectsForCount:20 width:400.0];
    NSInteger perRow = [BookshelfView booksPerRowForWidth:400.0];
    PASS(perRow >= 2 && perRow < 20, "several columns fit at width 400");
    NSRect first = [r[0] rectValue];
    NSRect nextRow = [r[perRow] rectValue];
    PASS(NSMaxY(first) < NSMaxY(nextRow), "second row lies below the first");
    PASS(NSMinY(first) >= 0.0 && NSMinY(first) < 100.0,
         "first shelf starts near the top of the document");
    PASS(NSMaxY(first) <= 240.0, "first shelf ends within its first row");
  }

  /* Positions depend only on the width, not on the height or on history. */
  {
    NSArray *a = [BookshelfView spineRectsForCount:20 width:517.3];
    NSArray *b = [BookshelfView spineRectsForCount:20 width:517.3];
    PASS_EQUAL(a, b, "same width gives the same positions");
    NSArray *c = [BookshelfView spineRectsForCount:20 width:517.9];
    PASS_EQUAL(a, c, "positions are stable while the column count is stable");
  }

  /* The view lays itself out again when the width changes, keeping
   * row 0 at the top whatever the frame height. */
  {
    BookshelfView *v = [[BookshelfView alloc]
        initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSMutableArray *books = [NSMutableArray array];
    for (int i = 0; i < 12; i++)
      [books addObject:[NSNull null]]; /* layout only counts books */
    [v setBooks:books];
    NSRect r0 = [v rectForBookAtIndex:0];
    [v setFrameSize:NSMakeSize(401, 900)];
    PASS_EQUAL([NSValue valueWithRect:r0],
               [NSValue valueWithRect:[v rectForBookAtIndex:0]],
               "growing height does not move the books");
    [v setFrameSize:NSMakeSize(1000, 300)];
    PASS(NSMaxY([v rectForBookAtIndex:11]) == NSMaxY(r0),
         "wider view puts all 12 books on the first row");
  }

  [arp release];
  return 0;
}
