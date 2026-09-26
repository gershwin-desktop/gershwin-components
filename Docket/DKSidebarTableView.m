/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKSidebarTableView.h"
#import "DKTexture.h"

@implementation DKSidebarTableView

- (void)drawBackgroundInClipRect: (NSRect)clipRect
{
  [DKTexture paintWoodGrainInRect: [self bounds]];
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
          [DKTexture paintSelectionInRect: rowRect tint: tint];
        }
      row = [rows indexGreaterThanIndex: row];
    }
}

@end
