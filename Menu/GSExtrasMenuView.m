/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSExtrasMenuView.h"
#import <GNUstepGUI/GSTheme.h>

@implementation GSExtrasMenuView

- (id)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    _measuringIndex = -1;
  }
  return self;
}

- (NSMenuItemCell *)menuItemCellForItemAtIndex:(NSInteger)index
{
  _measuringIndex = index;
  return [super menuItemCellForItemAtIndex:index];
}

- (NSInteger)measuringItemIndex
{
  return _measuringIndex;
}

- (void)setWidthProvider:(id<GSExtrasMenuViewWidthProvider>)provider
{
  _widthProvider = provider;
}

- (id<GSExtrasMenuViewWidthProvider>)widthProvider
{
  return _widthProvider;
}

/* The width of the items themselves: NSMenuView lays a horizontal menu out
 * from x = 0 and then sets the frame as wide as the SCREEN, so the frame
 * says nothing about how much of it is items.  The view's list of cells can
 * lag the menu's list of items by one notification, and asking for a rect it
 * has no cell for raises; that pass is then left alone, the next one (after
 * the notification) puts the group right. */
- (CGFloat)itemsWidth
{
  NSInteger count = (NSInteger)[[[self menu] itemArray] count];
  if (count == 0) {
    return 0.0;
  }
  @try {
    return NSMaxX([self rectOfItemAtIndex:count - 1]);
  } @catch (NSException *e) {
    return -1.0;
  }
}

/* Sizes the frame to the items and puts its right edge on the anchor.  The
 * area the view leaves behind is the superview's to repaint: a frame change
 * marks only the view itself. */
- (void)keepRightEdge
{
  if (!_anchored) {
    return;
  }
  CGFloat width = [self itemsWidth];
  if (width < 0.0) {
    return;
  }
  NSRect old = [self frame];
  NSRect wanted = NSMakeRect(_anchoredRightEdge - width, NSMinY(old), width, NSHeight(old));
  if (NSEqualRects(old, wanted)) {
    return;
  }
  [super setFrame:wanted];
  NSView *superview = [self superview];
  if (superview) {
    [superview setNeedsDisplayInRect:NSUnionRect(old, wanted)];
  }
}

- (void)setAnchoredRightEdge:(CGFloat)x
{
  _anchored = YES;
  _anchoredRightEdge = x;
  [self keepRightEdge];
}

/* Every layout pass ends here, the ones NSMenuView runs by itself after an
 * item changed included, so the group is back on its anchor before anything
 * is drawn. */
- (void)sizeToFit
{
  [super sizeToFit];
  [self keepRightEdge];
}

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self keepRightEdge];
}

@end

/* Horizontal menus only: the hook is reached for every menu view the theme
 * lays out, and the app menus and the dropdowns keep the width the theme
 * measured. */
@interface GSTheme (ExtrasMenuViewWidths)
@end

@implementation GSTheme (ExtrasMenuViewWidths)

- (CGFloat)proposedTitleWidth:(CGFloat)proposedWidth forMenuView:(NSMenuView *)aMenuView
{
  if (![aMenuView isKindOfClass:[GSExtrasMenuView class]]) {
    return proposedWidth;
  }
  GSExtrasMenuView *view = (GSExtrasMenuView *)aMenuView;
  id<GSExtrasMenuViewWidthProvider> provider = [view widthProvider];
  NSInteger index = [view measuringItemIndex];
  if (provider == nil || index < 0 || index >= (NSInteger)[[[view menu] itemArray] count]) {
    return proposedWidth;
  }
  return [provider extrasMenuView:view proposedTitleWidth:proposedWidth forItemAtIndex:index];
}

@end
