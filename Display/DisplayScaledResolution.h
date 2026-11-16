/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* "Looks like" sizes of one monitor: per-monitor scaling with a RandR
 * transform while the toolkit has one GSScaleFactor per process.
 *
 * Applications render at the global factor everywhere.  A monitor that
 * should look denser or coarser than that gets a framebuffer area of its
 * own size times t = global / wanted, and the server scales it onto the
 * panel through the CRTC transform (bilinear).  A 3840x2160 panel at
 * GSScaleFactor 2 normally looks like 1920x1080; with t = 4/3 it covers
 * 5120x2880 screen pixels and looks like 2560x1440.  The screen and the
 * neighbors' positions follow the transformed size, which the layout model
 * already uses for every frame.
 *
 * Foundation only, so every number has a headless test. */

#import <Foundation/Foundation.h>

@interface DisplayScaledResolution : NSObject
{
    int _logicalWidth;
    int _logicalHeight;
    int _framebufferWidth;
    int _framebufferHeight;
    double _transformScaleX;
    double _transformScaleY;
    double _effectiveScale;
    BOOL _isDefault;
}

/* The size applications see, in points at the global scale factor. */
@property (readonly) int logicalWidth;
@property (readonly) int logicalHeight;
/* Screen pixels the monitor covers (the transformed CRTC size). */
@property (readonly) int framebufferWidth;
@property (readonly) int framebufferHeight;
/* Screen pixels per mode pixel: the CRTC transform; 1.0 for the default. */
@property (readonly) double transformScaleX;
@property (readonly) double transformScaleY;
/* Panel pixels per point, the scale the monitor looks like it runs at. */
@property (readonly) double effectiveScale;
/* No transform: the mode shown at the global factor. */
@property (readonly) BOOL isDefault;

/* "2560 x 1440", with " (Default)" for the default. */
- (NSString *)title;

@end

/* The "looks like" sizes for a monitor running a mode of modeWidth x
 * modeHeight (as it lies on the screen, i.e. already rotated) while
 * applications render at globalScale.  One per offered scale step
 * (DisplayScaleFactorAtStep) that keeps the transform within 0.5 ... 2.0,
 * leaves at least 720 points of height and fits into a screen of
 * maxScreenWidth x maxScreenHeight (0 = unknown).  The default (no
 * transform) is always there.  Framebuffer sizes are rounded to even
 * numbers.  Sorted from the largest text to the most space. */
NSArray *DisplayScaledResolutions(int modeWidth, int modeHeight, double globalScale,
                                  int maxScreenWidth, int maxScreenHeight);

/* The option a transform (as read back from the server, i.e. after the
 * 16.16 fixed point round trip) selects, or nil when it is none of them
 * (e.g. the scale of a mirror). */
DisplayScaledResolution *DisplayScaledResolutionForTransform(NSArray *options,
                                                             double transformScaleX,
                                                             double transformScaleY);
