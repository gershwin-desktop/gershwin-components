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
 * An icon-only extra does not need this: with an empty title it is measured
 * the way Battery and WLAN are (the icon and the bar's padding), and that is
 * what keeps every icon-only item the same width.  Implement it only when
 * the whole item has to be a stated width; the bar then takes its own
 * padding and the icon out of it before laying the item out.
 *
 * An extra that implements this is measured by it in place of
 * -preferredWidth.  Extras with a title should use -preferredWidth.
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
