/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Pure geometry and mode decisions behind the Display pane.  Foundation
 * only and free of X calls, so every rule has a headless test. */

#import <Foundation/Foundation.h>

@class DisplayMode;

/* The user interface scale range the pane offers. */
extern const double DisplayScaleFactorMinimum;
extern const double DisplayScaleFactorMaximum;
/* The factors offered, the same steps LoginWindow's recommendation uses,
 * so a recommended factor is always one the slider can show. */
extern const NSUInteger DisplayScaleFactorStepCount;
double DisplayScaleFactorAtStep(NSUInteger index);
/* Index of the step nearest to `factor`. */
NSUInteger DisplayScaleFactorStepIndex(double factor);

/* The offered step nearest to `factor`. */
double DisplayClampScaleFactor(double factor);

/* The mode of an output's own list for width x height.  Progressive modes
 * beat interlaced ones; then a mode within 0.5 Hz of `refresh` (0 = no
 * wish), then the output's preferred mode, then the highest refresh.  nil
 * when the output has no mode of that size. */
DisplayMode *DisplaySelectMode(NSArray *modes, int width, int height,
                               double refresh);

/* The largest "WxH" every mode list in `modeLists` contains, or nil. */
NSString *DisplayCommonResolution(NSArray *modeLists);

/* Screen pixels an output of `length` mode pixels covers under a transform
 * scale, rounded the way the X server bounds a transformed CRTC (16.16
 * fixed point, rounded outwards), so the screen is never one pixel short. */
int DisplayTransformedExtent(int length, double scale);
/* The 16.16 fixed point value the server receives for a transform scale. */
int DisplayFixedFromDouble(double value);

/* Places rectangles (screen pixels, y down) so that none overlap and all
 * touch: the outputs form one connected arrangement without gaps.
 * `proposed` maps names to NSValue rects.  Outputs other than `moved` keep
 * their place as far as possible, the primary first; `moved` (may be nil)
 * is snapped last to the nearest free spot touching the others.  Edges
 * within `snap` pixels are aligned.  The result (name -> NSValue rect) is
 * shifted so the arrangement starts at 0,0, because X has no negative
 * screen coordinates. */
NSDictionary *DisplayArrangeRects(NSDictionary *proposed, NSString *primary,
                                  NSString *moved, CGFloat snap);

/* `frames` (name -> NSValue rect) with the rectangle of `resized` given
 * `newSize` at its own origin.  Rectangles lying wholly to its right or
 * below it move by the change in width or height, so they keep their side
 * and their contact with it; everything else stays.  Feed the result to
 * DisplayArrangeRects to repair what a shift alone cannot. */
NSDictionary *DisplayResizeRect(NSDictionary *frames, NSString *resized, NSSize newSize);

/* How the pane's arrangement view maps screen pixels to its own points: the
 * view is not flipped (y up) and scaled down. */
typedef struct {
    NSRect modelBounds;   /* screen area shown, screen pixels, y down */
    NSPoint viewOrigin;   /* view point of the bottom-left of modelBounds */
    CGFloat scale;        /* view points per screen pixel */
} DisplayViewMapping;

/* The mapping that fits `modelBounds` centered into `viewBounds` with
 * `margin` points around it, scaled down by at most `maxScale`. */
DisplayViewMapping DisplayViewMappingMake(NSRect modelBounds, NSRect viewBounds,
                                          CGFloat margin, CGFloat maxScale);
NSRect DisplayViewRectForModelRect(NSRect modelRect, DisplayViewMapping m);
/* Screen pixel position (top-left) for a rectangle dropped in the view. */
NSPoint DisplayModelOriginForViewRect(NSRect viewRect, DisplayViewMapping m);

/* Screen resizing around a layout change: the screen first grows to cover
 * both the current screen and the new layout, so no CRTC is ever set
 * outside it, and shrinks to the new layout once every CRTC is in place. */
typedef struct {
    NSSize grow;
    NSSize final;
} DisplayScreenSizePlan;
/* `frames`: NSValue rects each enabled output of the new layout needs on
 * the screen (-[DisplayOutput screenExtent]). */
DisplayScreenSizePlan DisplayPlanScreenSize(NSSize current, NSArray *frames);

/* CRTC for every output to enable.  `requests` is an array of dictionaries
 * with @"name", @"crtc" (current, 0 = none) and @"possible" (NSNumbers).
 * An output keeps its CRTC unless an earlier one already claimed it; the
 * rest get the first free CRTC they can drive.  Returns name -> NSNumber,
 * or nil when some output cannot get one (then *failed names it). */
NSDictionary *DisplayAssignCrtcs(NSArray *requests, NSString **failed);
