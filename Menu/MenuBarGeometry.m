/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 */

#import "MenuBarGeometry.h"
#import "PrimaryMonitor.h"

#include <math.h>

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

CGFloat MenuBarSlideInTop(CGFloat finalTop, CGFloat barHeight, CGFloat progress)
{
  CGFloat eased;

  if (progress < 0)
    progress = 0;
  if (progress > 1)
    progress = 1;
  /* Ease-out cubic: fast start, gentle stop. */
  eased = 1.0 - (1.0 - progress) * (1.0 - progress) * (1.0 - progress);
  return round(finalTop + barHeight - eased * barHeight);
}
