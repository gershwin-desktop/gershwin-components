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
 * NO with a description in *error when the server refused any step.
 * *touched (may be NULL) says whether the server was changed at all: a
 * request the checks refuse beforehand (no free CRTC, a mode the output
 * lacks, a screen too large) leaves it alone, so there is nothing to undo.
 * Ends by publishing the outputs' scales (-applyScalesOfLayout:...). */
- (BOOL)applyLayout:(DisplayLayout *)layout
      touchedServer:(BOOL *)touched
              error:(NSError **)error;

/* YES when the server runs something `layout` does not describe although
 * every output agrees with it: a CRTC still lit for a monitor that was
 * unplugged, or a screen larger or smaller than the lit outputs. */
/* Publishes each lit output's scale as its RandR "DPI" (96 per 1.0), on
 * the outputs whose value differs only (see DisplayShouldWriteDPI), so an
 * unchanged layout causes no events.  -applyLayout:... ends with this;
 * a change of scales alone needs no CRTC reconfiguration.  *changed (may
 * be NULL) says whether anything was written. */
- (BOOL)applyScalesOfLayout:(DisplayLayout *)layout
                    changed:(BOOL *)changed
                      error:(NSError **)error;

- (BOOL)hasStrayStateForLayout:(DisplayLayout *)layout;

/* The lit output RandR names as primary, or nil when the server has none
 * (a bare server until a client sets one) or it is dark. */
/* The largest screen the server allows (XRRGetScreenSizeRange); the
 * framebuffer of a scaled monitor must fit into it. */
- (NSSize)maximumScreenSize;

- (NSString *)primaryOutputName;
/* Makes `name` the RandR primary without touching any CRTC. */
- (BOOL)setPrimaryOutputNamed:(NSString *)name error:(NSError **)error;

@end
