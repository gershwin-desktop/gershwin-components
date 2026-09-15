/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/NSMenuItem.h>
#import <AppKit/NSMenuItemCell.h>

@class NSImage;

@interface NSMenuItemCell (TintedIcons)
@end

@interface NSMenuItem (TintedIcons)
/* Sets the icon of a menu bar item; while the item is highlighted the icon
   is shown in the highlighted title color. */
- (void) setMenuBarImage: (NSImage *)image;
@end
