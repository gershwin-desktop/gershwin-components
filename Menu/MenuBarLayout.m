/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuBarLayout.h"

@implementation MenuBarLayout

+ (CGFloat)widths:(NSArray<NSNumber *> *)widths sumFrom:(NSUInteger)from
{
    CGFloat total = 0;
    for (NSUInteger i = from; i < [widths count]; i++) {
        total += [widths[i] doubleValue];
    }
    return total;
}

+ (CGFloat)widths:(NSArray<NSNumber *> *)widths sumUpTo:(NSUInteger)upTo
{
    CGFloat total = 0;
    for (NSUInteger i = 0; i < upTo; i++) {
        total += [widths[i] doubleValue];
    }
    return total;
}

+ (void)layoutForBarWidth:(CGFloat)barWidth
                edgeMargin:(CGFloat)edgeMargin
               titleWidths:(NSArray<NSNumber *> *)titleWidths
        titleOverflowWidth:(CGFloat)titleOverflowWidth
               extraWidths:(NSArray<NSNumber *> *)extraWidths
        extraOverflowWidth:(CGFloat)extraOverflowWidth
         visibleTitleCount:(NSUInteger *)outVisibleTitleCount
      collapsedExtraCount:(NSUInteger *)outCollapsedExtraCount
{
    NSUInteger titleCount = [titleWidths count];
    NSUInteger extraCount = [extraWidths count];
    CGFloat available = barWidth - edgeMargin;
    CGFloat titlesTotal = [self widths:titleWidths sumUpTo:titleCount];

    /* Collapse extras from the front (least important, nearest the
     * titles) one at a time until the untouched titles fit alongside
     * whatever extras remain - status icons give way before any
     * application menu title does. */
    for (NSUInteger collapsed = 0; collapsed <= extraCount; collapsed++) {
        CGFloat extrasWidth = [self widths:extraWidths sumFrom:collapsed];
        if (collapsed > 0) {
            extrasWidth += extraOverflowWidth;
        }
        if (titlesTotal + extrasWidth <= available) {
            *outVisibleTitleCount = titleCount;
            *outCollapsedExtraCount = collapsed;
            return;
        }
    }

    /* Even with every extra folded into one overflow item, the titles do
     * not fit on their own: fold titles from the end into a trailing
     * overflow item too, keeping as many of the leftmost (most-used)
     * titles visible as possible. */
    CGFloat extrasWidth = (extraCount > 0) ? extraOverflowWidth : 0;
    CGFloat titleBudget = available - extrasWidth;

    NSUInteger visible = titleCount;
    for (; visible > 0; visible--) {
        CGFloat width = [self widths:titleWidths sumUpTo:visible];
        if (visible < titleCount) {
            width += titleOverflowWidth;
        }
        if (width <= titleBudget) {
            break;
        }
    }

    *outVisibleTitleCount = visible;
    *outCollapsedExtraCount = extraCount;
}

@end
