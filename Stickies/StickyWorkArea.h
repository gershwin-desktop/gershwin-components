/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class NSScreen;

@interface StickyWorkArea : NSObject

// The part of the screen the window manager leaves free of struts (menu bar,
// dock), read from _NET_WORKAREA instead of -[NSScreen visibleFrame]: the
// backend drops the work area on machines with more than one video output,
// even when only one of them is connected.
+ (NSRect)usableFrameOfScreen:(NSScreen *)screen;

@end
