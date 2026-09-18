/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <X11/Xlib.h>

@protocol WindowMonitorDelegate <NSObject>
@required
- (void)activeWindowChanged:(unsigned long)windowId;
@end

// Notification posted on main thread when active window changes
extern NSString * const WindowMonitorActiveWindowChangedNotification;

// Posted on the main thread when a root-window property we track is
// rewritten by someone else (e.g. a WM reassertion timer).  userInfo
// contains the property's atom name under @"atom".
extern NSString * const WindowMonitorRootPropertyChangedNotification;

/**
 * WindowMonitor
 * 
 * Efficient GCD-based X11 active window monitoring using _NET_ACTIVE_WINDOW.
 * Zero-polling, event-driven design using dispatch source for X11 file descriptor.
 */
@interface WindowMonitor : NSObject

@property (nonatomic, weak) id<WindowMonitorDelegate> delegate;
@property (nonatomic, assign, readonly) Display *display;
@property (nonatomic, assign, readonly) Window rootWindow;
@property (nonatomic, assign, readonly) unsigned long currentActiveWindow;

+ (instancetype)sharedMonitor;

/**
 * Start monitoring _NET_ACTIVE_WINDOW property changes.
 * Uses GCD dispatch source for X11 file descriptor - no polling.
 */
- (BOOL)startMonitoring;

/**
 * Stop monitoring and clean up resources.
 */
- (void)stopMonitoring;

/**
 * Check if a window is a GNUstep window.
 */
- (BOOL)isGNUstepWindow:(unsigned long)windowId;

/**
 * Get the current active window immediately.
 */
- (unsigned long)getActiveWindow;

@end
