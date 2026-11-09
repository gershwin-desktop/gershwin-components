/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Recommended user space scale (GSScaleFactor) for a monitor, from its pixel
 * size and the physical size the display reports (EDID, as RandR mm_width and
 * mm_height). Foundation only, so the Display pane, displayconfig and
 * LoginWindow share it. */
@interface DisplayScaleHeuristic : NSObject

/* The steps the Display pane offers: 1.0 1.25 1.5 1.75 2.0 2.5 3.0 (NSNumber). */
+ (NSArray *)supportedScales;

/* One of supportedScales. 1.0 whenever the physical size is missing or not
 * believable, because a wrong guess makes the whole desktop unusable while 1.0
 * is merely small. */
+ (double)recommendedScaleForPixelWidth:(NSUInteger)pixelWidth
                            pixelHeight:(NSUInteger)pixelHeight
                      millimeterWidth:(NSUInteger)millimeterWidth
                     millimeterHeight:(NSUInteger)millimeterHeight;

@end
