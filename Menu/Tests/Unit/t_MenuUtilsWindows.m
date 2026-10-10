/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* XQueryTree returns a nonzero Status on success.  The window scans compared
   it with Success (0), so on a healthy connection they skipped their whole
   body and also never freed the child list Xlib had allocated: Menu found no
   windows to probe and leaked one list per scan.  Needs an X display; without
   one the test reports that it did not run. */

#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#include <unistd.h>
#import "Testing.h"
#import "../../MenuUtils.h"

static int IgnoreXError(Display *d, XErrorEvent *e) { return 0; }

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  Display *dpy = XOpenDisplay(NULL);
  if (dpy == NULL)
    {
      fprintf(stderr, "t_MenuUtilsWindows: no X display, not run\n");
      [arp release];
      return 0;
    }

  XSetErrorHandler(IgnoreXError);
  Window root = DefaultRootWindow(dpy);

  /* A plain mapped top-level window: any window manager frames it, so the
     scan sees at least this window or its frame. */
  Window plain = XCreateSimpleWindow(dpy, root, 10, 10, 50, 50, 0, 0, 0);
  XStoreName(dpy, plain, "t_MenuUtilsWindows");
  XMapWindow(dpy, plain);

  /* A desktop-type window.  Override-redirect keeps a window manager from
     reparenting it, so it stays a direct child of the root, where the scan
     looks for the type property. */
  XSetWindowAttributes attrs;
  attrs.override_redirect = True;
  Window desktop = XCreateWindow(dpy, root, 0, 0, 80, 80, 0, CopyFromParent,
    InputOutput, CopyFromParent, CWOverrideRedirect, &attrs);
  Atom typeAtom = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  Atom desktopAtom = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
  XChangeProperty(dpy, desktop, typeAtom, XA_ATOM, 32, PropModeReplace,
    (unsigned char *)&desktopAtom, 1);
  XMapWindow(dpy, desktop);
  XSync(dpy, False);

  /* A window manager maps the frame a moment after the request. */
  NSArray *windows = [MenuUtils getAllWindows];
  for (int i = 0; i < 30 && [windows count] == 0; i++)
    {
      usleep(100000);
      windows = [MenuUtils getAllWindows];
    }
  PASS([windows count] > 0, "getAllWindows lists the mapped top-level windows");

  PASS([MenuUtils findDesktopWindow] == (unsigned long)desktop,
    "findDesktopWindow finds the window of desktop type");

  XDestroyWindow(dpy, plain);
  XDestroyWindow(dpy, desktop);
  XCloseDisplay(dpy);

  [arp release];
  return 0;
}
