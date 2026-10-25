/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
 *
 * PrimaryMonitorQuery() against a live X server whose outputs it changes
 * with xrandr: a resize, a primary-only change and an unplugged primary,
 * all read over ONE connection that never processes RandR events, as
 * Menu's shared Display does.  Opt-in: it reconfigures the display, so it
 * runs only with PRIMARY_MONITOR_LIVE_DISPLAY naming a disposable Xorg
 * with the dummy driver (outputs DUMMY0 and DUMMY1), never a desktop.
 * Recipe: SUPERAGENT/runs/display135/phase3/RECIPE.txt.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../PrimaryMonitor.h"
#include <stdlib.h>

static NSString * const kSuiteName = @"PrimaryMonitor against a live X server";

static void Run(const char *display, const char *args)
{
  char cmd[512];

  snprintf(cmd, sizeof(cmd), "DISPLAY=%s xrandr %s", display, args);
  if (system(cmd) != 0)
    fprintf(stderr, "command failed: %s\n", cmd);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  const char *display = getenv("PRIMARY_MONITOR_LIVE_DISPLAY");
  Display *dpy;
  NSRect r;
  NSSize root;

  NSLog(@"%@", kSuiteName);
  if (display == NULL)
    {
      NSLog(@"PRIMARY_MONITOR_LIVE_DISPLAY not set; skipped");
      [arp release];
      return 0;
    }

  Run(display, "--addmode DUMMY0 1280x800");
  Run(display, "--addmode DUMMY1 1024x768");
  Run(display, "--fb 2304x800 --output DUMMY0 --mode 1280x800 --pos 0x0 "
               "--primary --output DUMMY1 --mode 1024x768 --pos 1280x0");

  dpy = XOpenDisplay(display);
  NEED(PASS(dpy != NULL, "opened the live display"));

  PrimaryMonitorQuery(dpy, &r, &root);
  PASS(NSEqualRects(r, NSMakeRect(0, 0, 1280, 800))
       && root.width == 2304 && root.height == 800,
       "primary DUMMY0 on the left, root 2304x800");

  Run(display, "--output DUMMY1 --primary");
  PrimaryMonitorQuery(dpy, &r, &root);
  PASS(NSEqualRects(r, NSMakeRect(1280, 0, 1024, 768)),
       "a primary-only change is seen on the same connection");

  Run(display, "--output DUMMY1 --off --fb 1280x800");
  PrimaryMonitorQuery(dpy, &r, &root);
  PASS(NSEqualRects(r, NSMakeRect(0, 0, 1280, 800)),
       "the unplugged primary falls back to the monitor at 0,0");
  PASS(root.width == 1280 && root.height == 800,
       "the root size follows the resize on a connection that never "
       "processes RandR events (DisplayWidth there still says %d)",
       DisplayWidth(dpy, DefaultScreen(dpy)));

  Run(display, "--fb 2304x800 --output DUMMY1 --mode 1024x768 --pos 1280x0 "
               "--output DUMMY0 --primary");
  XCloseDisplay(dpy);
  [arp release];
  return 0;
}
