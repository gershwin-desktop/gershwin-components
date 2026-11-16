/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGGridLayout.h"

@implementation AGGridLayout
{
  NSSize _cardSize;
  CGFloat _minimumGap;
  CGFloat _sideInset;
}

- (instancetype)initWithCardSize:(NSSize)size minimumGap:(CGFloat)gap sideInset:(CGFloat)inset
{
  self = [super init];
  if (self == nil)
    return nil;

  NSParameterAssert(size.width > 0 && size.height > 0);
  NSParameterAssert(gap >= 0 && inset >= 0);

  _cardSize = size;
  _minimumGap = gap;
  _sideInset = inset;
  return self;
}

// Width needed for a given number of columns at the minimum gap, used both
// to pick the column count and to know when a column no longer fits.
- (CGFloat)widthForColumns:(NSUInteger)columns
{
  return 2 * _sideInset
    + columns * _cardSize.width
    + (columns - 1) * _minimumGap;
}

- (NSUInteger)columnsForWidth:(CGFloat)width
{
  NSUInteger columns = 1;
  while ([self widthForColumns:columns + 1] <= width)
    columns++;
  return columns;
}

- (CGFloat)horizontalGapForWidth:(CGFloat)width
{
  NSUInteger columns = [self columnsForWidth:width];
  if (columns < 2)
    return _minimumGap;

  CGFloat spread = (width - 2 * _sideInset - columns * _cardSize.width)
    / (CGFloat)(columns - 1);
  return (spread > _minimumGap) ? spread : _minimumGap;
}

- (NSRect)frameForIndex:(NSUInteger)i width:(CGFloat)width
{
  NSUInteger columns = [self columnsForWidth:width];
  CGFloat gap = [self horizontalGapForWidth:width];
  NSUInteger column = i % columns;
  NSUInteger row = i / columns;

  return NSMakeRect(_sideInset + column * (_cardSize.width + gap),
                    _sideInset + row * (_cardSize.height + _minimumGap),
                    _cardSize.width,
                    _cardSize.height);
}

- (CGFloat)heightForCount:(NSUInteger)n width:(CGFloat)width
{
  if (n == 0)
    return 0;

  NSUInteger columns = [self columnsForWidth:width];
  NSUInteger rows = (n + columns - 1) / columns;
  return 2 * _sideInset
    + rows * _cardSize.height
    + (rows - 1) * _minimumGap;
}

- (NSInteger)indexAtPoint:(NSPoint)p width:(CGFloat)width count:(NSUInteger)n
{
  if (n == 0 || p.x < _sideInset || p.y < _sideInset)
    return -1;

  NSUInteger columns = [self columnsForWidth:width];
  CGFloat columnStep = _cardSize.width + [self horizontalGapForWidth:width];
  NSUInteger column = (NSUInteger)((p.x - _sideInset) / columnStep);
  if (column >= columns)
    return -1;
  if (p.x > _sideInset + column * columnStep + _cardSize.width)
    return -1;

  CGFloat rowStep = _cardSize.height + _minimumGap;
  NSUInteger row = (NSUInteger)((p.y - _sideInset) / rowStep);
  if (p.y > _sideInset + row * rowStep + _cardSize.height)
    return -1;

  NSUInteger index = row * columns + column;
  return (index < n) ? (NSInteger)index : -1;
}

@end
