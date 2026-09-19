/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickyWorkArea.h"
#import <AppKit/NSScreen.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

static unsigned long *copyCardinals(Display *dpy, Window root, const char *name,
                                    unsigned long *count)
{
    Atom type;
    int format;
    unsigned long bytesAfter;
    unsigned char *data = NULL;

    *count = 0;
    if (XGetWindowProperty(dpy, root, XInternAtom(dpy, name, False), 0, ~0L,
                           False, XA_CARDINAL, &type, &format, count,
                           &bytesAfter, &data) != Success || data == NULL) {
        return NULL;
    }
    if (format != 32 || *count == 0) {
        XFree(data);
        *count = 0;
        return NULL;
    }
    // Xlib hands out 32 bit properties as longs, whatever their size.
    return (unsigned long *)data;
}

@implementation StickyWorkArea

+ (NSRect)usableFrameOfScreen:(NSScreen *)screen
{
    NSRect screenFrame = [screen frame];
    Display *dpy = (Display *)[GSCurrentServer() serverDevice];
    if (dpy == NULL) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Stickies needs the X11 display server"];
    }
    Window root = DefaultRootWindow(dpy);

    unsigned long count;
    unsigned long *areas = copyCardinals(dpy, root, "_NET_WORKAREA", &count);
    if (areas == NULL) {
        // Without the property the window manager reserves nothing.
        return screenFrame;
    }

    // The property lists one rectangle per virtual desktop.
    unsigned long desktop = 0;
    unsigned long desktopCount;
    unsigned long *current = copyCardinals(dpy, root, "_NET_CURRENT_DESKTOP",
                                           &desktopCount);
    if (current != NULL) {
        desktop = current[0];
        XFree(current);
    }
    if ((desktop + 1) * 4 > count) {
        desktop = 0;
    }

    XWindowAttributes rootAttributes;
    XGetWindowAttributes(dpy, root, &rootAttributes);

    unsigned long *a = areas + desktop * 4;
    NSRect workArea = NSMakeRect(a[0],
                                 rootAttributes.height - a[1] - a[3],
                                 a[2], a[3]);
    XFree(areas);

    // The work area spans all monitors; only this screen's share counts.
    return NSIntersectionRect(workArea, screenFrame);
}

@end
