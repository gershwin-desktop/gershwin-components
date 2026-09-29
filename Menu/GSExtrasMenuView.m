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
