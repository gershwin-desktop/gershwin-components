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
#import <X11/Xutil.h>
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

  /* isWindowValid: made the same comparison with XGetWindowAttributes, so
     it called every live window gone: the periodic reconcile then dropped
     the cached menu of each open window, and a later menu change from that
     window (Emacs switching its major-mode menu) never reached the menu bar. */
  PASS([MenuUtils isWindowValid:(unsigned long)plain],
    "isWindowValid: is true for an existing window");

  /* isWindowMapped: had the same comparison, so it assumed every window
     mapped and the watchdog never noticed an unmapped one. */
  PASS([MenuUtils isWindowMapped:(unsigned long)plain],
    "isWindowMapped: is true for a mapped window");

  /* isRealApplicationWindow:onDisplay: had it too and called every
     managed, mapped application window not real: the window monitor then
     kept reporting the previous active window, and Menu showed the previous
     application's menu over Claude or TextEdit. */
  Atom wmState = XInternAtom(dpy, "WM_STATE", False);
  long normalState[2] = { NormalState, None };
  XChangeProperty(dpy, plain, wmState, wmState, 32, PropModeReplace,
    (unsigned char *)normalState, 2);
  Atom normalAtom = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_NORMAL", False);
  XChangeProperty(dpy, plain, typeAtom, XA_ATOM, 32, PropModeReplace,
    (unsigned char *)&normalAtom, 1);
  XSync(dpy, False);
  PASS([MenuUtils isRealApplicationWindow:(unsigned long)plain onDisplay:dpy],
    "isRealApplicationWindow:onDisplay: is true for a managed, mapped window");

  XUnmapWindow(dpy, plain);
  XSync(dpy, False);
  PASS(![MenuUtils isWindowMapped:(unsigned long)plain],
    "isWindowMapped: is false for an unmapped window");
  PASS([MenuUtils isWindowValid:(unsigned long)plain],
    "an unmapped window is still valid");

  XDestroyWindow(dpy, plain);
  XDestroyWindow(dpy, desktop);
  XSync(dpy, False);

  PASS(![MenuUtils isWindowMapped:(unsigned long)plain],
    "isWindowMapped: is false for a destroyed window");

  PASS(![MenuUtils isWindowValid:(unsigned long)plain],
    "isWindowValid: is false for a destroyed window");

  XCloseDisplay(dpy);

  [arp release];
  return 0;
}
