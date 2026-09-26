/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKTaskOutlineView.h"
#import "DKTexture.h"

@implementation DKTaskOutlineView

- (void)drawBackgroundInClipRect: (NSRect)clipRect
{
  [DKTexture paintLeatherInRect: [self bounds]];
}

- (void)highlightSelectionInClipRect: (NSRect)clipRect
{
  NSIndexSet *rows = [self selectedRowIndexes];
  NSUInteger row = [rows firstIndex];
  NSColor *tint = [NSColor colorWithCalibratedRed: 0.92 green: 0.68 blue: 0.28 alpha: 1.0];

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
