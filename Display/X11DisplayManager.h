/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DisplayLayout;

extern NSString * const X11DisplayManagerErrorDomain;

/* Reads the RandR state of the X server into a DisplayLayout and applies a
 * DisplayLayout to it.  All decisions (modes, CRTCs, screen size, mirror
 * transforms) come from the Foundation-only model; this class only talks
 * to the server. */
@interface X11DisplayManager : NSObject
{
    void *_display;     // Display*
    int _screen;
    unsigned long _root; // Window
}

- (BOOL)isAvailable;

/* The connected outputs with their modes, positions, primary and
 * transforms; nil when RandR cannot be queried.  With `probe` the server
 * asks the hardware again which monitors are connected, like xrandr does:
 * outputs without hotplug detection (VGA, some docks) only show up that
 * way, but probing can take a moment, so it is not for periodic polling. */
- (DisplayLayout *)currentLayoutProbingOutputs:(BOOL)probe;

/* Configures the server like `layout`: newly enabled outputs get a free
 * CRTC, modes come from each output's own list, the screen grows before
 * and shrinks after the CRTCs change, and the primary is set.  CRTCs of
 * outputs that are off, or no longer connected, are switched off.  Returns
 * NO with a description in *error when the server refused any step. */
- (BOOL)applyLayout:(DisplayLayout *)layout error:(NSError **)error;

@end
