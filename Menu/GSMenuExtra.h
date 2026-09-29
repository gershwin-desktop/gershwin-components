/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GSMenuExtraContext;

@protocol GSMenuExtra <NSObject>

@required

- (NSMenu *)menu;
- (NSImage *)image;
- (NSString *)title;

@optional

- (NSView *)customView;

/**
 * The width of this extra's TITLE, plus its own padding.  The bar adds the
 * icon and its own padding on top of this, so an extra with both a title and
 * an icon should ask for the title's width and let the bar do the rest.
 */
- (CGFloat)preferredWidth;

/**
 * The WHOLE width this extra wants in the menu bar: icon, title and the
 * bar's padding, all of it.
 *
 * For an extra with no title, which is most icon-only ones: there is no
 * title to measure, so -preferredWidth has nothing to say and the item would
 * come out as wide as the bar's chrome alone - or, if the chrome were taken
 * out of it, wider than asked for, pushing every extra to the left along
 * with it.  Say the total here instead and the bar will honour it exactly.
 *
 * An extra that implements this is measured by it in place of
 * -preferredWidth.  Extras with a title should use -preferredWidth and need
 * not implement this at all.
 */
- (CGFloat)totalWidthInMenuBar;

/**
 * Return YES while this extra has nothing to show, and it should take no
 * room in the menu bar at all.
 *
 * This is not the same as a -preferredWidth of 0.  The bar adds its own
 * padding to whatever width an item asks for, so an item asking for nothing
 * still reserves that padding and leaves a visible gap; only leaving the bar
 * removes it.  An extra whose content comes and goes - a transport that
 * appears when something is plugged in, a player that shows up and goes
 * quiet - implements this, and the extras either side of it close up.
 *
 * Extras that always have something to show need not implement it.
 */
- (BOOL)isHiddenFromMenuBar;

- (void)menuExtraDidLoad;
- (void)menuExtraWillUnload;
- (void)menuExtraWillOpenMenu;
- (void)menuExtraDidCloseMenu;
- (void)setContext:(GSMenuExtraContext *)context;

/**
 * Return NO if this MenuExtra is incompatible with the current hardware
 * (e.g., BatteryExtra when no battery is present).  Incompatible extras
 * are not loaded even if enabled, and do not appear in the preferences
 * panel.  Defaults to YES when not implemented.
 */
- (BOOL)isCompatibleWithSystem;

/**
 * Return YES if this MenuExtra belongs in the menu bar from the moment it is
 * installed, without the user having to find it in the preferences first
 * (e.g. MediaExtra, which a media key acts on).  Such an extra is put into
 * the saved GSMenuExtraEnabled set once, when it is first seen; unticking it
 * afterwards sticks, like unticking any other extra.  Defaults to NO when
 * not implemented.
 */
- (BOOL)enabledByDefault;

@end
