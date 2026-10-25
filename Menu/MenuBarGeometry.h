/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 */

#ifndef MENU_BAR_GEOMETRY_H
#define MENU_BAR_GEOMETRY_H

#import <Foundation/Foundation.h>

/* Where the menu bar goes, decided from the primary monitor alone so that
 * the application menu on the left and the menu extras on the right always
 * share one monitor, whatever else is connected. */
typedef struct {
  /* The bar window, GNUstep screen coordinates, device pixels. */
  NSRect windowFrame;
  /* The bar's views, in points (the window's user space). */
  NSSize contentSize;
  /* _NET_WM_STRUT_PARTIAL; the first four values are _NET_WM_STRUT. */
  unsigned long strut[12];
} MenuBarGeometry;

/* primaryXRect and rootSize in X root coordinates (device pixels), as
 * PrimaryMonitorQuery() returns them; themeHeight is the theme's bar height
 * in points; scale is GSScaleFactor. */
MenuBarGeometry MenuBarGeometryForMonitor(NSRect primaryXRect, NSSize rootSize,
                                          CGFloat themeHeight, CGFloat scale);

/* Top edge (GNUstep screen coordinates, device pixels) of the bar during
 * its slide-in from one bar height above finalTop, for progress 0..1
 * (eased out).  Whole pixels only: the X11 backend truncates a fractional
 * window position, and NSWindow treats the final exact frame as equal to
 * an almost-equal fractional one and skips it, so the bar stayed a pixel
 * too high once the backend reported the truncated position back. */
CGFloat MenuBarSlideInTop(CGFloat finalTop, CGFloat barHeight, CGFloat progress);

#endif
