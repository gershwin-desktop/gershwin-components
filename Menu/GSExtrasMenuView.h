/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class GSExtrasMenuView;

/* Whoever knows how wide each extra wants to be. */
@protocol GSExtrasMenuViewWidthProvider <NSObject>
/* The title width the view should lay the item at index out with, given the
 * width the theme measured from the item's title.  Called once per item on
 * every layout pass of the view. */
- (CGFloat)extrasMenuView:(GSExtrasMenuView *)view
       proposedTitleWidth:(CGFloat)proposedWidth
           forItemAtIndex:(NSInteger)index;
@end

/* The horizontal menu view that holds the menu extras.
 *
 * The theme measures the items of a menu view through
 * -proposedTitleWidth:forMenuView:, a hook that is told the view but not
 * which item is being measured.  The view knows: NSMenuView asks it for the
 * item's cell right before it asks the theme for the width, so the index of
 * the last cell handed out is the index of the item under measurement, and
 * that is what the hook passes on to the width provider.  Counting the
 * hook's calls instead, as the bar used to, breaks the moment a layout pass
 * runs over a different number of items than the last one - an extra that
 * comes and goes, one folded into the overflow - and every item is then laid
 * out at its neighbour's width until a later pass happens to line up again:
 * percentages overdrawn by the next icon, highlights beside their icons, the
 * clock pushed off the screen. */
@interface GSExtrasMenuView : NSMenuView
{
  NSInteger _measuringIndex;
  id<GSExtrasMenuViewWidthProvider> _widthProvider;
}

/* The index of the item whose cell was fetched last, or -1 before any. */
- (NSInteger)measuringItemIndex;

/* Not retained: the provider owns the view. */
- (void)setWidthProvider:(id<GSExtrasMenuViewWidthProvider>)provider;
- (id<GSExtrasMenuViewWidthProvider>)widthProvider;

@end
