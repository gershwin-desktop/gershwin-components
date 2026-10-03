/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Pure geometry for the global menu bar.  Given the natural (unclipped)
 * width of the active application's own top-level menu titles and of the
 * loaded menu extras, decides how many of each a bar of a given width can
 * show directly, following the rule a Mac-style bar uses: the app's own
 * titles keep priority.  When everything does not fit, extras collapse
 * first (least important - i.e. nearest the titles - hidden behind a
 * single leading overflow item); only when the titles alone still do not
 * fit do they, too, fold into a single trailing overflow item, instead of
 * either one being silently pushed off the edge of the bar.
 *
 * No AppKit dependency: this can be exercised headless, with no display.
 */
@interface MenuBarLayout : NSObject

/* titleWidths: natural width of each of the active application's top-level
 *   menu items, in left-to-right display order.
 * titleOverflowWidth: width of the single trailing item that stands in for
 *   whatever titles get folded away.
 * extraWidths: natural width of each menu extra, ordered LEAST important
 *   first - the order they are dropped in when the bar runs out of room
 *   (nearest the titles; farthest from the screen edge/clock).
 * extraOverflowWidth: width of the single leading item that stands in for
 *   whatever extras get folded away.
 *
 * On return, *outVisibleTitleCount is the number of leading titles from
 * titleWidths to draw directly (the rest, if any, belong to the trailing
 * overflow item; equal to [titleWidths count] when every title fits), and
 * *outCollapsedExtraCount is the number of leading extras from extraWidths
 * to fold into the leading overflow item (0 when none need to collapse).
 */
+ (void)layoutForBarWidth:(CGFloat)barWidth
                edgeMargin:(CGFloat)edgeMargin
               titleWidths:(NSArray<NSNumber *> *)titleWidths
        titleOverflowWidth:(CGFloat)titleOverflowWidth
               extraWidths:(NSArray<NSNumber *> *)extraWidths
        extraOverflowWidth:(CGFloat)extraOverflowWidth
         visibleTitleCount:(NSUInteger *)outVisibleTitleCount
      collapsedExtraCount:(NSUInteger *)outCollapsedExtraCount;

@end
