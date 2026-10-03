/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WindowMonitor.h"
#import "MenuUtils.h"
#import "MenuController.h"
#import "MenuProfiler.h"
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <dispatch/dispatch.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>

@interface WindowMonitor ()
{
    Display *_display;
    Window _rootWindow;
    Atom _netActiveWindowAtom;
    Atom _gershwinActiveAppAtom;
    unsigned long _currentActiveWindow;
    unsigned long _viewableActiveWindow;
    BOOL _activeWindowUnviewable;
    BOOL _monitoring;
    BOOL _stopMonitoring;
}
- (void)_postWindowNotification:(NSDictionary *)userInfo;
- (void)_noteActiveWindow:(unsigned long)window
                 viewable:(BOOL)viewable;
@end

@implementation WindowMonitor

NSString * const WindowMonitorActiveWindowChangedNotification = @"WindowMonitorActiveWindowChangedNotification";
NSString * const WindowMonitorRootPropertyChangedNotification = @"WindowMonitorRootPropertyChangedNotification";
NSString * const WindowMonitorViewableActiveWindowNotification = @"WindowMonitorViewableActiveWindowNotification";

- (void)_postViewableWindowNotification:(NSDictionary *)userInfo
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:WindowMonitorViewableActiveWindowNotification
                      object:self
                    userInfo:userInfo];
}

/* Reports _NET_ACTIVE_WINDOW unfiltered, as soon as it can be seen.  The
   controller used to read it every 100 ms on the main thread for this, and
   those two round trips per tick were most of what an idle Menu did and
   woke the X server twenty times a second. */
- (void)_noteActiveWindow:(unsigned long)window
                 viewable:(BOOL)viewable
{
    /* An active window that is not mapped yet shows up by a MapNotify of
       its own or of its frame, with no change of the root property. */
    _activeWindowUnviewable = (window != 0 && !viewable);
    unsigned long shown = viewable ? window : 0;
    if (shown == _viewableActiveWindow) {
        return;
    }
    _viewableActiveWindow = shown;
    if (shown != 0) {
        [self performSelectorOnMainThread:@selector(_postViewableWindowNotification:)
                               withObject:@{@"windowId": @(shown)}
                            waitUntilDone:NO];
    }
}

- (void)_postRootPropertyNotification:(NSDictionary *)userInfo
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:WindowMonitorRootPropertyChangedNotification
                      object:self
                    userInfo:userInfo];
}


- (void)_postWindowNotification:(NSDictionary *)userInfo
{
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:WindowMonitorActiveWindowChangedNotification
        object:self
        userInfo:userInfo];
}

+ (instancetype)sharedMonitor
{
    static WindowMonitor *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _display = NULL;
        _rootWindow = 0;
        _netActiveWindowAtom = 0;
        _gershwinActiveAppAtom = 0;
        _currentActiveWindow = 0;
        _viewableActiveWindow = 0;
        _activeWindowUnviewable = NO;
        _monitoring = NO;
        _stopMonitoring = NO;
        
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Initialized");
    }
    return self;
}

- (void)dealloc
{
    [self stopMonitoring];
}

- (BOOL)startMonitoring
{
    MENU_PROFILE_BEGIN(startMonitoring);

    if (_monitoring) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Already monitoring");
        MENU_PROFILE_END(startMonitoring);
        return YES;
    }

    /* Plain event-loop thread on its OWN X connection.  No GCD: a dispatch
     * read-source on an Xlib fd has been observed to stop firing after a
     * while, leaving the menu stuck on the previously active app. */
    _monitoring = YES;
    _stopMonitoring = NO;
    [NSThread detachNewThreadSelector: @selector(x11EventLoop:)
                            toTarget: self
                          withObject: nil];

    MENU_PROFILE_END(startMonitoring);
    return YES;
}

- (void)x11EventLoop:(id)unused
{
    @autoreleasepool {
        _display = XOpenDisplay(NULL);
        if (!_display) {
            NSLog(@"WindowMonitor: Cannot open X display for event loop");
            _monitoring = NO;
            return;
        }
        _rootWindow = DefaultRootWindow(_display);
        _netActiveWindowAtom = XInternAtom(_display, "_NET_ACTIVE_WINDOW", False);
        _gershwinActiveAppAtom = XInternAtom(_display, "_GERSHWIN_ACTIVE_APP", False);
        Atom netSupportedAtom = XInternAtom(_display, "_NET_SUPPORTED", False);
        XSelectInput(_display, _rootWindow, PropertyChangeMask | SubstructureNotifyMask);
        XSync(_display, False);

        NSLog(@"WindowMonitor: Event loop started on own connection");
        [self checkInitialActiveWindow];

        while (!_stopMonitoring) {
            /* One pool per event, not one for the whole loop: this thread
               never leaves the loop, so a pool around it would hold every
               object autoreleased for every X event until the session ends,
               and a busy desktop sends them by the thousand per minute. */
            @autoreleasepool {
                XEvent event;
                XNextEvent(_display, &event);
                if (event.type == PropertyNotify
                    && event.xproperty.window == _rootWindow
                    && event.xproperty.atom == _netActiveWindowAtom) {
                    [self checkActiveWindow];
                } else if (event.type == PropertyNotify
                    && event.xproperty.window == _rootWindow
                    && event.xproperty.atom == _gershwinActiveAppAtom) {
                    /* The frontmost application changed without a window change
                       (e.g. Alt-Tab between two windowless apps).  Re-post the
                       current active window (0 when windowless) so the widget
                       re-evaluates its application-level menu. */
                    NSDictionary *userInfo = @{@"windowId": @(_currentActiveWindow)};
                    [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                                           withObject:userInfo
                                        waitUntilDone:NO];
                } else if (event.type == PropertyNotify
                    && event.xproperty.window == _rootWindow
                    && event.xproperty.atom == netSupportedAtom) {
                    /* Something rewrote the WM-owned _NET_SUPPORTED list (e.g. a
                       window-manager property-reassertion timer); let the
                       controller restore our merged global-menu atoms. */
                    NSDictionary *userInfo = @{@"atom": @"_NET_SUPPORTED"};
                    [self performSelectorOnMainThread:@selector(_postRootPropertyNotification:)
                                           withObject:userInfo
                                        waitUntilDone:NO];
                } else if (event.type == DestroyNotify || event.type == UnmapNotify) {
                    Window affected = (event.type == DestroyNotify)
                        ? event.xdestroywindow.window : event.xunmap.window;
                    if (affected != 0 && (affected == _currentActiveWindow
                                          || affected == _viewableActiveWindow)) {
                        [self checkActiveWindow];
                    }
                } else if (event.type == MapNotify && _activeWindowUnviewable) {
                    [self checkActiveWindow];
                }
            }
        }

        XCloseDisplay(_display);
        _display = NULL;
        _monitoring = NO;
        NSLog(@"WindowMonitor: Event loop stopped");
    }
}

- (void)checkInitialActiveWindow
{
    MENU_PROFILE_BEGIN(checkInitialActiveWindow);

    if (!_display) {
        MENU_PROFILE_END(checkInitialActiveWindow);
        return;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    unsigned long newActiveWindow = 0;
    
    if (XGetWindowProperty(_display, _rootWindow, _netActiveWindowAtom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        newActiveWindow = *(Window*)prop;
        XFree(prop);
    }

    // Same logic as checkActiveWindow - trust WM unless window is explicitly unmapped
    if (newActiveWindow == 0) {
        [self _noteActiveWindow:0 viewable:NO];
    } else {
        XWindowAttributes attrs;
        BOOL canGetAttrs = XGetWindowAttributes(_display, (Window)newActiveWindow, &attrs);
        [self _noteActiveWindow:newActiveWindow
                       viewable:(canGetAttrs && attrs.map_state == IsViewable)];
        
        if (canGetAttrs && attrs.map_state != IsViewable) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
            // Require IsViewable: reject both IsUnmapped and IsUnviewable (mapped but ancestor unmapped).
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Initial active window %lu is not viewable (map_state %d)", newActiveWindow, attrs.map_state);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Cannot get attributes for initial window %lu - trusting WM", newActiveWindow);
        }
        
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
        }
    }
    
    // Same ICCCM/EWMH filter as checkActiveWindow - ignore internal windows.
    if (newActiveWindow != 0
        && ![MenuUtils isDesktopWindow:newActiveWindow onDisplay:_display]
        && ![MenuUtils isRealApplicationWindow:newActiveWindow onDisplay:_display]) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Initial active window %lu is not a real app window - ignoring", newActiveWindow);
        newActiveWindow = 0;
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    }

    MENU_PROFILE_END(checkInitialActiveWindow);
}

- (void)checkActiveWindow
{

    MENU_PROFILE_BEGIN(checkActiveWindow);

    if (!_display) {
        MENU_PROFILE_END(checkActiveWindow);
        return;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    unsigned long newActiveWindow = 0;
    
    if (XGetWindowProperty(_display, _rootWindow, _netActiveWindowAtom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        newActiveWindow = *(Window*)prop;
        XFree(prop);
    }

    // FIX: Don't report window==0 unless X11 truly says there's no active window
    // If XGetWindowProperty returns a window ID, trust it - even if we can't query its attributes
    // Window attributes can fail during WM operations (reparenting, etc) but the window is still valid
    if (newActiveWindow == 0) {
        [self _noteActiveWindow:0 viewable:NO];
    } else {
        XWindowAttributes attrs;
        // Try to get attributes, but don't reject the window if this fails
        // The window manager set this as active, so trust it
        BOOL canGetAttrs = XGetWindowAttributes(_display, (Window)newActiveWindow, &attrs);
        [self _noteActiveWindow:newActiveWindow
                       viewable:(canGetAttrs && attrs.map_state == IsViewable)];
        
        if (canGetAttrs && attrs.map_state != IsViewable) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
            // Require IsViewable: reject both IsUnmapped (minimized/hidden) and
            // IsUnviewable (mapped but an ancestor is not). Neither can have focus.
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window %lu is not viewable (map_state %d) - treating as no active window", newActiveWindow, attrs.map_state);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            // Can't get attributes - might be during WM operation
            // Only ignore if we get a BadWindow error, otherwise keep it
            // For now, trust the window manager's report
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Cannot get attributes for active window %lu - trusting WM report anyway", newActiveWindow);
        }
        
        // Select for events on this window if we can
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
        }
    }
    
    // ICCCM/EWMH filter: window-manager-internal windows (tooltips, menus,
    // popups, docks) and Chromium's internal helper windows must not be
    // treated as the active app window.  When one of them grabs the focus,
    // keep showing the previous app's menu (and its shortcuts) instead of
    // clearing to system-only.  The desktop is still reported as-is so the
    // menu can go to its system-only state.
    if (newActiveWindow != 0
        && ![MenuUtils isDesktopWindow:newActiveWindow onDisplay:_display]
        && ![MenuUtils isRealApplicationWindow:newActiveWindow onDisplay:_display]) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window %lu is not a real app window - keeping current %lu", newActiveWindow, _currentActiveWindow);
        newActiveWindow = _currentActiveWindow;
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window changed from %lu to %lu", _currentActiveWindow, newActiveWindow);

        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    } else {
        // Window hasn't changed - suppress notification to avoid spam
        // This can happen during WM operations or when we check after a window closes
    }

    MENU_PROFILE_END(checkActiveWindow);
}

- (void)stopMonitoring
{
    if (!_monitoring) return;

    /* Signal the event-loop thread to exit; it owns _display and closes it. */
    _stopMonitoring = YES;
    if (_display) {
        /* Wake the thread out of XNextEvent with a client message.  It is sent
         * on a connection of our own: _display belongs to the event-loop
         * thread, and Xlib aborts when two threads use one connection. */
        Display *waker = XOpenDisplay(NULL);
        if (waker) {
            XEvent e;
            memset(&e, 0, sizeof(e));
            e.type = ClientMessage;
            e.xclient.window = _rootWindow;
            e.xclient.message_type = _netActiveWindowAtom;
            XSendEvent(waker, _rootWindow, False,
                       SubstructureRedirectMask | SubstructureNotifyMask, &e);
            XSync(waker, False);
            XCloseDisplay(waker);
        } else {
            NSLog(@"WindowMonitor: Cannot open X display to stop the event loop");
        }
    }
    for (int i = 0; i < 100 && _monitoring; i++) {
        [NSThread sleepForTimeInterval:0.02];
    }
    NSDebugLLog(@"gwcomp", @"WindowMonitor: Stopped monitoring");
}

// Compatibility Accessors
- (Window)rootWindow { return _rootWindow; }
- (unsigned long)currentActiveWindow
{
    return _currentActiveWindow;
}

- (unsigned long)getActiveWindow
{
    return _currentActiveWindow;
}

@end
