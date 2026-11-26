/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Pure geometry for the card grid: how many columns fit, where each card
// goes, and which card a click lands on. No AppKit, so it can be tested
// without a window server.
//
// The frames are in flipped coordinates, first row at the top with y growing
// downwards, because AGAppGridView flips itself to lay cards out the way the
// user reads them (see the grid view in the view layer).
@interface AGGridLayout : NSObject

- (instancetype)initWithCardSize:(NSSize)size minimumGap:(CGFloat)gap sideInset:(CGFloat)inset;

// At least 1, whatever the width.
- (NSUInteger)columnsForWidth:(CGFloat)width;

// The spare width goes into the gaps so the cards spread evenly instead of
// piling up against a right margin; the gap never shrinks below the minimum.
- (CGFloat)horizontalGapForWidth:(CGFloat)width;

- (NSRect)frameForIndex:(NSUInteger)i width:(CGFloat)width;

- (CGFloat)heightForCount:(NSUInteger)n width:(CGFloat)width;

// The card under a point, or -1 when the point falls in a gap, in an inset,
// or past the last card.
- (NSInteger)indexAtPoint:(NSPoint)p width:(CGFloat)width count:(NSUInteger)n;

@end
