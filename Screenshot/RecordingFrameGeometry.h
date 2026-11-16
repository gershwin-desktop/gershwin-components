/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef RecordingFrameGeometry_h
#define RecordingFrameGeometry_h

#import <Foundation/Foundation.h>
#include <math.h>

/* The sides of the recorded area, as a bit mask. */
enum {
    RecordingSideLeft = 1,
    RecordingSideRight = 2,
    RecordingSideBottom = 4,
    RecordingSideTop = 8
};

/* A side that ends up this close to a screen border is put on it, so an
 * area can reach all the way to the border without pixel-exact aiming. */
static inline NSRect
RecordingSnapResize(NSRect area, int sides, NSRect screen, CGFloat reach)
{
    CGFloat minX = NSMinX(area), maxX = NSMaxX(area);
    CGFloat minY = NSMinY(area), maxY = NSMaxY(area);

    if ((sides & RecordingSideLeft) && fabs(minX - NSMinX(screen)) <= reach)
        minX = NSMinX(screen);
    if ((sides & RecordingSideRight) && fabs(maxX - NSMaxX(screen)) <= reach)
        maxX = NSMaxX(screen);
    if ((sides & RecordingSideBottom) && fabs(minY - NSMinY(screen)) <= reach)
        minY = NSMinY(screen);
    if ((sides & RecordingSideTop) && fabs(maxY - NSMaxY(screen)) <= reach)
        maxY = NSMaxY(screen);
    return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

/* Moving keeps the size; the area is shifted onto a border it nearly
 * touches. */
static inline NSRect
RecordingSnapMove(NSRect area, NSRect screen, CGFloat reach)
{
    if (fabs(NSMinX(area) - NSMinX(screen)) <= reach)
        area.origin.x = NSMinX(screen);
    else if (fabs(NSMaxX(area) - NSMaxX(screen)) <= reach)
        area.origin.x = NSMaxX(screen) - NSWidth(area);
    if (fabs(NSMinY(area) - NSMinY(screen)) <= reach)
        area.origin.y = NSMinY(screen);
    else if (fabs(NSMaxY(area) - NSMaxY(screen)) <= reach)
        area.origin.y = NSMaxY(screen) - NSHeight(area);
    return area;
}

/* The sides lying on a screen border; their part of the frame would be
 * off the screen. */
static inline int
RecordingSidesOnScreenBorder(NSRect area, NSRect screen)
{
    int sides = 0;
    if (NSMinX(area) <= NSMinX(screen))
        sides |= RecordingSideLeft;
    if (NSMaxX(area) >= NSMaxX(screen))
        sides |= RecordingSideRight;
    if (NSMinY(area) <= NSMinY(screen))
        sides |= RecordingSideBottom;
    if (NSMaxY(area) >= NSMaxY(screen))
        sides |= RecordingSideTop;
    return sides;
}

#endif /* RecordingFrameGeometry_h */
