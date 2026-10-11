/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MenuInstanceTakeover.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static NSString *MenuReadLink(NSString *linkPath)
{
    char buffer[PATH_MAX];
    ssize_t len = readlink([linkPath fileSystemRepresentation], buffer, sizeof(buffer) - 1);
    if (len == -1) {
        return nil;
    }
    buffer[len] = '\0';
    return [NSString stringWithUTF8String:buffer];
}

NSString *MenuExecutablePathForProcess(pid_t pid)
{
    // Linux procfs names it exe, the BSD procfs file.
    NSString *linked = MenuReadLink([NSString stringWithFormat:@"/proc/%d/exe", (int)pid]);
    if (!linked) {
        linked = MenuReadLink([NSString stringWithFormat:@"/proc/%d/file", (int)pid]);
    }
    if (!linked) {
        return nil;
    }
    char resolved[PATH_MAX];
    if (realpath([linked fileSystemRepresentation], resolved) == NULL) {
        return linked;
    }
    return [NSString stringWithUTF8String:resolved];
}

pid_t MenuPreviousInstanceToTerminate(pid_t ownerPID,
                                      pid_t ownPID,
                                      NSString *ownExecutable,
                                      NSString *(^executableForPID)(pid_t pid))
{
    if (ownerPID <= 0 || ownerPID == ownPID || ownExecutable == nil) {
        return 0;
    }
    // The selection owner id comes from the X server; never signal a process
    // that is not a copy of this program.
    if (![executableForPID(ownerPID) isEqualToString:ownExecutable]) {
        return 0;
    }
    return ownerPID;
}

void MenuTerminateProcess(pid_t pid)
{
    NSLog(@"Menu.app: Terminating previous Menu with PID %d", (int)pid);
    kill(pid, SIGTERM);
    for (int waitedMs = 0; waitedMs < 2000; waitedMs += 100) {
        usleep(100000);
        if (kill(pid, 0) != 0) {
            return;
        }
    }
    NSLog(@"Menu.app: Force killing previous Menu with PID %d", (int)pid);
    kill(pid, SIGKILL);
}

static pid_t MenuPIDOfWindow(Display *dpy, Window window)
{
    Atom pidAtom = XInternAtom(dpy, "_NET_WM_PID", False);
    Atom type = None;
    int format = 0;
    unsigned long count = 0, remaining = 0;
    unsigned char *data = NULL;
    pid_t pid = 0;

    if (XGetWindowProperty(dpy, window, pidAtom, 0, 1, False, XA_CARDINAL,
                           &type, &format, &count, &remaining, &data) == Success
        && type == XA_CARDINAL && format == 32 && count == 1) {
        pid = (pid_t)*(unsigned long *)data;
    }
    if (data) {
        XFree(data);
    }
    return pid;
}

static int MenuIgnoreXError(Display *dpy, XErrorEvent *event)
{
    (void)dpy;
    (void)event;
    return 0;
}

BOOL MenuTakeOverDisplay(void)
{
    // Not closed on purpose: the selection lives as long as this connection.
    Display *dpy = XOpenDisplay(NULL);
    if (dpy == NULL) {
        NSLog(@"Menu.app: Cannot open X display %s", getenv("DISPLAY") ? getenv("DISPLAY") : "(DISPLAY unset)");
        return NO;
    }

    // The previous owner may vanish between the queries.
    XErrorHandler previousHandler = XSetErrorHandler(MenuIgnoreXError);

    char atomName[64];
    snprintf(atomName, sizeof(atomName), "_GERSHWIN_MENU_S%d", DefaultScreen(dpy));
    Atom selection = XInternAtom(dpy, atomName, False);

    Window owner = XGetSelectionOwner(dpy, selection);
    if (owner != None) {
        NSString *ownExecutable = MenuExecutablePathForProcess(getpid());
        pid_t victim = MenuPreviousInstanceToTerminate(MenuPIDOfWindow(dpy, owner), getpid(),
                                                       ownExecutable,
                                                       ^NSString *(pid_t pid) {
                                                           return MenuExecutablePathForProcess(pid);
                                                       });
        if (victim > 0) {
            MenuTerminateProcess(victim);
        }
    }

    Window root = DefaultRootWindow(dpy);
    Window ownerWindow = XCreateSimpleWindow(dpy, root, -1, -1, 1, 1, 0, 0, 0);
    unsigned long ownPID = (unsigned long)getpid();
    XChangeProperty(dpy, ownerWindow, XInternAtom(dpy, "_NET_WM_PID", False), XA_CARDINAL,
                    32, PropModeReplace, (unsigned char *)&ownPID, 1);
    XSetSelectionOwner(dpy, selection, ownerWindow, CurrentTime);
    XSync(dpy, False);

    XSetErrorHandler(previousHandler);
    return XGetSelectionOwner(dpy, selection) == ownerWindow;
}
