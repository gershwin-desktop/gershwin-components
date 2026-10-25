/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 */

#import "MenuBarGeometry.h"
#import "PrimaryMonitor.h"

MenuBarGeometry MenuBarGeometryForMonitor(NSRect primaryXRect, NSSize rootSize,
                                          CGFloat themeHeight, CGFloat scale)
{
  MenuBarGeometry g;
  NSRect barXRect;

  if (scale <= 0)
    scale = 1.0;

  /* The bar's height grows with the scale factor, its width stays the
   * monitor's width in device pixels. */
  barXRect = NSMakeRect(NSMinX(primaryXRect), NSMinY(primaryXRect),
                        NSWidth(primaryXRect), themeHeight * scale);
  g.windowFrame = PrimaryMonitorFlipRect(barXRect, rootSize.height);
  g.contentSize = NSMakeSize(NSWidth(primaryXRect) / scale, themeHeight);
  PrimaryMonitorStrutForPanel(barXRect, rootSize, PrimaryMonitorEdgeTop, g.strut);
  return g;
}
