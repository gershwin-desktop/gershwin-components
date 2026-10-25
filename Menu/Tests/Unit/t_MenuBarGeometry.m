/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 *
 * Coverage for MenuBarGeometryForMonitor(): the bar window, its content
 * size and its strut come from the primary monitor only, so the global menu
 * and the menu extras share that monitor (issue #135).  Headless.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../MenuBarGeometry.h"

static NSString * const kSuiteName = @"Menu bar on the primary monitor";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSLog(@"%@", kSuiteName);

  /* Laptop 1280x800 primary at 0,0, external 1920x1080 right of it. */
  NSSize root = NSMakeSize(3200, 1080);

  {
    MenuBarGeometry g = MenuBarGeometryForMonitor(NSMakeRect(0, 0, 1280, 800),
                                                  root, 22, 1.0);
    PASS(g.windowFrame.size.width == 1280,
         "bar is as wide as the primary monitor, not the whole X screen");
    PASS(g.windowFrame.origin.x == 0 && g.windowFrame.origin.y == 1058
         && g.windowFrame.size.height == 22,
         "bar sits at the top of the primary in GNUstep coordinates (1080 - 22)");
    PASS(g.contentSize.width == 1280 && g.contentSize.height == 22,
         "content spans the primary's width at scale 1");
    PASS(g.strut[2] == 22 && g.strut[8] == 0 && g.strut[9] == 1279,
         "strut reserves the top 22 px over the primary's columns only");
  }

  {
    /* The external monitor made primary, scale 2. */
    MenuBarGeometry g = MenuBarGeometryForMonitor(NSMakeRect(1280, 0, 1920, 1080),
                                                  root, 22, 2.0);
    PASS(g.windowFrame.origin.x == 1280 && g.windowFrame.size.width == 1920,
         "bar moves to the primary's origin and width when the primary changes");
    PASS(g.windowFrame.size.height == 44 && g.windowFrame.origin.y == 1036,
         "bar height scales with GSScaleFactor");
    PASS(g.contentSize.width == 960 && g.contentSize.height == 22,
         "content is in points: 1920 px / 2");
    PASS(g.strut[2] == 44 && g.strut[8] == 1280 && g.strut[9] == 3199,
         "strut follows the primary to the right monitor");
  }

  {
    /* Primary placed lower than the root top (stacked layout): no strut,
     * or the window manager would take 1102 px off the upper monitor. */
    MenuBarGeometry g = MenuBarGeometryForMonitor(NSMakeRect(0, 1080, 1280, 800),
                                                  NSMakeSize(1920, 1880), 22, 1.0);
    PASS(g.windowFrame.origin.y == 778,
         "a primary below another monitor puts the bar at its own top");
    PASS(g.strut[2] == 0 && g.strut[8] == 0 && g.strut[9] == 0,
         "a bar below the root top reserves nothing");
  }

  [arp release];
  return 0;
}
