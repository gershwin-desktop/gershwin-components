/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <X11/Xlib.h>

@interface MenuUtils : NSObject

+ (Display *)sharedDisplay;
+ (void)cleanup;

// Hand the pages of freed heap memory back to the system.  For after work
// that allocates a lot and frees it again; costs a few milliseconds.
+ (void)releaseFreedHeapMemory;

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId;
+ (BOOL)isWindowValid:(unsigned long)windowId;
+ (BOOL)isWindowMapped:(unsigned long)windowId;
+ (BOOL)isDesktopWindow:(unsigned long)windowId;
// Same check on a connection the caller owns, for threads with their own.
+ (BOOL)isDesktopWindow:(unsigned long)windowId onDisplay:(Display *)display;
+ (BOOL)isDialogWindow:(unsigned long)windowId;
// True for a real top-level application window per ICCCM/EWMH: viewable, not
// override-redirect, and with a normal/dialog/utility _NET_WM_WINDOW_TYPE (or
// no type at all).  Window-manager-internal windows (tooltips, menus, docks,
// notifications) and Chromium's internal helper windows that Chromium marks as
// non-normal are excluded, so the global menu does not chase them.  Queried
// on the caller's own connection: the shared display is used by the main
// thread, and Xlib aborted when another thread used it at the same time.
+ (BOOL)isRealApplicationWindow:(unsigned long)windowId onDisplay:(Display *)display;
// Read _NET_ACTIVE_WINDOW on a fresh connection (safe from any thread).
+ (unsigned long)getActiveWindowFresh;
+ (NSArray *)getAllWindows;
+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName;
+ (NSString*)getWindowMenuService:(unsigned long)windowId;
+ (NSString*)getWindowMenuPath:(unsigned long)windowId;
+ (BOOL)setWindowMenuService:(NSString*)service path:(NSString*)path forWindow:(unsigned long)windowId;
+ (NSDictionary *)getAllVisibleWindowApplications;
+ (unsigned long)findDesktopWindow;
+ (pid_t)getWindowPID:(unsigned long)windowId;
+ (BOOL)advertiseGlobalMenuSupport;
+ (void)removeGlobalMenuSupport;

/* ── Gershwin root-window "active application" properties ──────────────
   The WM maintains _GERSHWIN_ACTIVE_APP (Cardinal = PID of the frontmost
   application) and clears _NET_ACTIVE_WINDOW when a windowless app is the
   frontmost.  Menu.app reads the PID to decide which app menu to show.
   Menu.app maintains _GERSHWIN_MENU_APPS (array of Cardinal PIDs of apps
   that have an application-level menu); the WM's Alt-Tab reads it to list
   windowless apps. */
+ (pid_t)getActiveApplicationPID;
+ (NSArray *)getMenuApps;
+ (void)setMenuApps:(NSArray *)pids;

/* Merge the given atoms into the root window's _NET_SUPPORTED property.
 * _NET_SUPPORTED is owned by the window manager; this appends the global-menu
 * atoms without dropping the entries the WM advertised (e.g. the window
 * animation protocol atoms), which a plain PropModeReplace would clobber. */
+ (void)mergeNetSupportedAtoms:(const Atom *)atoms
                         count:(unsigned long)count
                         onRoot:(Window)root
                       display:(Display *)display;

/* Merge the standard set of global-menu atoms into root _NET_SUPPORTED. */
+ (void)mergeDefaultGlobalMenuAtomsOnRoot:(Window)root
                                  display:(Display *)display;

/* Like mergeDefaultGlobalMenuAtomsOnRoot:display:, and also publish the same
 * atoms as _UNITY_SUPPORTED. */
+ (void)announceGlobalMenuAtomsOnRoot:(Window)root
                              display:(Display *)display;

/* Re-merge the global-menu atoms when the WM-owned _NET_SUPPORTED list was
 * rewritten without them (e.g. by a window-manager property-reassertion
 * timer).  Returns YES when a write was needed. */
+ (BOOL)reassertGlobalMenuAtomsOnRootIfNeeded;

/**
 * Returns YES if the window has any X11 property that indicates it intends to
 * export an application menu (GTK _GTK_UNIQUE_BUS_NAME, Canonical/KDE
 * _KDE_NET_WM_APPMENU_SERVICE_NAME, or GNUstep _GNUSTEP_WM_ATTR).
 * Used to decide whether to wait for a menu to appear after a window switch.
 */
+ (BOOL)windowIndicatesMenuSupport:(unsigned long)windowId;

@end
