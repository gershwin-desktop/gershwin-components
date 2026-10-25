/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 */

#import "MenuBarGeometry.h"
#import "PrimaryMonitor.h"

#include <math.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xrandr.h>

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

CGFloat MenuBarScaleForMonitor(long dpi, CGFloat globalScale)
{
  if (dpi > 0)
    return dpi / 96.0;
  return (globalScale > 0) ? globalScale : 1.0;
}

static long OutputDPI(Display *dpy, RROutput output, Atom dpiAtom)
{
  Atom type;
  int format;
  unsigned long count, after;
  unsigned char *data = NULL;
  long dpi = 0;

  if (XRRGetOutputProperty(dpy, output, dpiAtom, 0, 1, False, False,
                           AnyPropertyType, &type, &format, &count, &after,
                           &data) != Success)
    return 0;
  /* The same shape libs-back accepts, so both read the same value. */
  if (data != NULL && type == XA_INTEGER && format == 32 && count == 1)
    dpi = *(long *)data;
  if (data != NULL)
    XFree(data);
  return dpi;
}

long MenuBarMonitorDPI(Display *dpy, NSRect xRect)
{
  Window root;
  Atom dpiAtom;
  XRRScreenResources *res;
  long dpi = 0;
  int i;

  if (dpy == NULL)
    return 0;
  /* Only an atom somebody created can be set on an output. */
  dpiAtom = XInternAtom(dpy, "DPI", True);
  if (dpiAtom == None)
    return 0;
  root = RootWindow(dpy, DefaultScreen(dpy));
  res = XRRGetScreenResourcesCurrent(dpy, root);
  if (res == NULL)
    return 0;
  for (i = 0; i < res->noutput && dpi == 0; i++)
    {
      XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);

      if (oi == NULL)
        continue;
      if (oi->crtc != None)
        {
          XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);

          if (ci != NULL)
            {
              if (NSEqualRects(NSMakeRect(ci->x, ci->y, ci->width, ci->height), xRect))
                dpi = OutputDPI(dpy, res->outputs[i], dpiAtom);
              XRRFreeCrtcInfo(ci);
            }
        }
      XRRFreeOutputInfo(oi);
    }
  XRRFreeScreenResources(res);
  return dpi;
}
