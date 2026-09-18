/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RunningApplicationList.h"

#import <X11/Xlib.h>
#import <X11/Xatom.h>

/* Windows in _NET_CLIENT_LIST may already be gone; ignore the error instead
 * of letting the default handler terminate the process. */
static int RunningApplicationListXErrorHandler(Display *display, XErrorEvent *error)
{
    (void)display;
    (void)error;
    return 0;
}

@implementation RunningApplicationList

+ (NSArray *)applicationsOwningWindows
{
    NSMutableDictionary *namesByPid = [NSMutableDictionary dictionary];
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        NSLog(@"RunningApplicationList: Cannot open X display");
        return @[];
    }

    XErrorHandler previousHandler = XSetErrorHandler(RunningApplicationListXErrorHandler);

    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    Atom pidAtom = XInternAtom(display, "_NET_WM_PID", False);
    Atom wmClassAtom = XInternAtom(display, "WM_CLASS", False);
    Atom listType, propType, pidType;
    int listFormat, propFormat, pidFormat;
    unsigned long listNitems, propNitems, pidNitems;
    unsigned long listBytesAfter, propBytesAfter, pidBytesAfter;
    unsigned char *prop = NULL;

    if (XGetWindowProperty(display, DefaultRootWindow(display), clientListAtom,
                           0, 1024, False, XA_WINDOW,
                           &listType, &listFormat, &listNitems, &listBytesAfter,
                           &prop) == 0 && prop) {
        Window *wins = (Window *)prop;
        for (unsigned long i = 0; i < listNitems; i++) {
            /* WM_CLASS is two null-terminated strings; the class is the
               second one. */
            unsigned char *classProp = NULL;
            if (XGetWindowProperty(display, wins[i], wmClassAtom, 0, 32, False,
                                   XA_STRING, &propType, &propFormat, &propNitems,
                                   &propBytesAfter, &classProp) == 0
                && classProp && propFormat == 8) {
                char *p = strchr((char *)classProp, '\0');
                if (p && p[1] != '\0') {
                    NSString *name = [NSString stringWithUTF8String:p + 1];
                    unsigned char *pidProp = NULL;
                    pid_t pid = 0;
                    if (XGetWindowProperty(display, wins[i], pidAtom, 0, 1, False,
                                           XA_CARDINAL, &pidType, &pidFormat,
                                           &pidNitems, &pidBytesAfter,
                                           &pidProp) == 0 && pidProp && pidFormat == 32) {
                        pid = (pid_t)((long *)pidProp)[0];
                        XFree(pidProp);
                    }
                    if (pid > 0 && name) {
                        [namesByPid setObject:name forKey:[NSNumber numberWithInt:(int)pid]];
                    }
                }
                XFree(classProp);
            }
        }
        XFree(prop);
    }
    XCloseDisplay(display);
    XSetErrorHandler(previousHandler);

    /* Menu hosts the power actions and the Force Quit panel, so it must never
       offer to end itself. */
    [namesByPid removeObjectForKey:[NSNumber numberWithInt:(int)getpid()]];

    NSMutableArray *result = [NSMutableArray array];
    for (NSNumber *pid in namesByPid) {
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [namesByPid objectForKey:pid], @"name",
            pid, @"pid", nil]];
    }
    return result;
}

@end
