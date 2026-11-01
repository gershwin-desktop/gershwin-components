/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDSidebarTableView.h"
#import "TDTexture.h"

@implementation TDSidebarTableView

- (void)drawBackgroundInClipRect: (NSRect)clipRect
{
  [TDTexture paintWoodGrainInRect: [self bounds]];
}

- (void)highlightSelectionInClipRect: (NSRect)clipRect
{
  NSIndexSet *rows = [self selectedRowIndexes];
  NSUInteger row = [rows firstIndex];
  NSColor *tint = [NSColor colorWithCalibratedRed: 0.62 green: 0.42 blue: 0.18 alpha: 1.0];

  while (row != NSNotFound)
    {
      NSRect rowRect = [self rectOfRow: row];

      if (NSIntersectsRect(rowRect, clipRect))
        {
          [TDTexture paintSelectionInRect: rowRect tint: tint];
        }
      row = [rows indexGreaterThanIndex: row];
    }
}

@end
