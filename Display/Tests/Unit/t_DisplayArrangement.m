/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_DisplayArrangement - mode selection, arrangement, view mapping, screen
 * size planning and CRTC assignment of the Display pane.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayLayout.h"
#import "DisplayArrangement.h"

static NSString * const kPrimaryName = @"primary-output";

static DisplayMode *M(unsigned long ident, int w, int h, double r, BOOL pref)
{
    return [DisplayMode modeWithID:ident width:w height:h refresh:r
                        interlaced:NO preferred:pref];
}

static NSValue *R(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
    return [NSValue valueWithRect:NSMakeRect(x, y, w, h)];
}

static NSRect rectOf(NSDictionary *d, NSString *k)
{
    return [[d objectForKey:k] rectValue];
}

static BOOL overlapsNone(NSDictionary *rects)
{
    NSArray *keys = [rects allKeys];
    for (NSUInteger i = 0; i < [keys count]; i++) {
        for (NSUInteger j = i + 1; j < [keys count]; j++) {
            NSRect a = rectOf(rects, [keys objectAtIndex:i]);
            NSRect b = rectOf(rects, [keys objectAtIndex:j]);
            if (NSIntersectsRect(a, b)) return NO;
        }
    }
    return YES;
}

static BOOL touches(NSRect a, NSRect b)
{
    BOOL xTouch = (NSMaxX(a) == NSMinX(b) || NSMaxX(b) == NSMinX(a))
        && NSMinY(a) < NSMaxY(b) && NSMinY(b) < NSMaxY(a);
    BOOL yTouch = (NSMaxY(a) == NSMinY(b) || NSMaxY(b) == NSMinY(a))
        && NSMinX(a) < NSMaxX(b) && NSMinX(b) < NSMaxX(a);
    return xTouch || yTouch;
}

/* Every rect reachable from every other through shared edges. */
static BOOL connected(NSDictionary *rects)
{
    NSArray *keys = [rects allKeys];
    if ([keys count] < 2) return YES;
    NSMutableSet *seen = [NSMutableSet setWithObject:[keys objectAtIndex:0]];
    BOOL grew = YES;
    while (grew) {
        grew = NO;
        for (NSString *k in keys) {
            if ([seen containsObject:k]) continue;
            for (NSString *s in [seen allObjects]) {
                if (touches(rectOf(rects, k), rectOf(rects, s))) {
                    [seen addObject:k];
                    grew = YES;
                    break;
                }
            }
        }
    }
    return [seen count] == [keys count];
}

static BOOL startsAtOrigin(NSDictionary *rects)
{
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    for (NSString *k in rects) {
        minX = MIN(minX, NSMinX(rectOf(rects, k)));
        minY = MIN(minY, NSMinY(rectOf(rects, k)));
    }
    return minX == 0 && minY == 0;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("mode selection uses the output's own modes")
    {
        NSArray *modes = [NSArray arrayWithObjects:
            M(0x50, 1920, 1080, 60.0, YES), M(0x51, 1920, 1080, 75.0, NO),
            M(0x52, 1280, 1024, 60.0, NO), M(0x53, 1280, 1024, 75.0, NO),
            M(0x54, 1280, 1024, 85.0, NO), nil];

        PASS(DisplaySelectMode(modes, 2560, 1440, 0) == nil,
             "a size the output does not list resolves to no mode");
        PASS([DisplaySelectMode(modes, 1920, 1080, 0) modeID] == 0x50,
             "without a refresh wish the preferred mode wins");
        PASS([DisplaySelectMode(modes, 1920, 1080, 75.0) modeID] == 0x51,
             "a matching refresh rate wins over the preferred mode");
        PASS([DisplaySelectMode(modes, 1920, 1080, 74.8) modeID] == 0x51,
             "a refresh within half a hertz counts as matching");
        PASS([DisplaySelectMode(modes, 1920, 1080, 50.0) modeID] == 0x50,
             "an unmatched refresh falls to the preferred mode");
        PASS([DisplaySelectMode(modes, 1280, 1024, 0) modeID] == 0x54,
             "without a preferred mode of that size the highest refresh wins");

        NSArray *interlaced = [NSArray arrayWithObjects:
            [DisplayMode modeWithID:0x60 width:1920 height:1080 refresh:60.0
                         interlaced:YES preferred:YES],
            M(0x61, 1920, 1080, 50.0, NO), nil];
        PASS([DisplaySelectMode(interlaced, 1920, 1080, 60.0) modeID] == 0x61,
             "a progressive mode beats an interlaced one");
    }
    END_SET("mode selection uses the output's own modes")

    START_SET("common resolution for mirroring")
    {
        NSArray *a = [NSArray arrayWithObjects:M(1, 1920, 1080, 60, YES),
            M(2, 1280, 1024, 60, NO), M(3, 1024, 768, 60, NO), nil];
        NSArray *b = [NSArray arrayWithObjects:M(4, 1680, 1050, 60, YES),
            M(5, 1280, 1024, 60, NO), M(6, 1024, 768, 60, NO), nil];
        NSArray *c = [NSArray arrayWithObjects:M(7, 3840, 2160, 60, YES), nil];
        NSArray *ab = [NSArray arrayWithObjects:a, b, nil];
        NSArray *ac = [NSArray arrayWithObjects:a, c, nil];
        PASS_EQUAL(DisplayCommonResolution(ab), @"1280x1024",
                   "the largest size both outputs list is chosen");
        PASS(DisplayCommonResolution(ac) == nil,
             "no common size gives nil");
    }
    END_SET("common resolution for mirroring")

    START_SET("transformed extent")
    {
        PASS(DisplayTransformedExtent(1920, 1.0) == 1920, "no transform");
        PASS(DisplayTransformedExtent(1920, 2048.0 / 1920.0) == 2048,
             "a scale up to the primary's width covers it exactly");
        PASS(DisplayTransformedExtent(1280, 1.5) == 1920, "scale 1.5");
        PASS(DisplayTransformedExtent(2560, 1920.0 / 2560.0) == 1920,
             "a scale down covers the primary's width exactly");
    }
    END_SET("transformed extent")

    START_SET("arrangement: no overlaps, no gaps, vertical placement")
    {
        NSDictionary *res;
        NSMutableDictionary *p = [NSMutableDictionary dictionary];

        /* Dropped half over the primary: pushed to the free side. */
        [p setObject:R(0, 0, 1920, 1080) forKey:kPrimaryName];
        [p setObject:R(1000, 0, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 50);
        PASS(NSEqualRects(rectOf(res, @"B"), NSMakeRect(1920, 0, 1920, 1080)),
             "an overlapping drop lands right of the primary");
        PASS(NSEqualPoints(rectOf(res, kPrimaryName).origin, NSZeroPoint),
             "the primary stays at 0,0 when nothing is left of or above it");

        /* Dropped with a gap: pulled in until the edges touch. */
        [p setObject:R(2500, 40, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 50);
        PASS(NSEqualRects(rectOf(res, @"B"), NSMakeRect(1920, 0, 1920, 1080)),
             "a gap is closed and a near edge aligned");

        /* Dropped above the primary: vertical arrangement. */
        [p setObject:R(100, -1200, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 150);
        PASS(NSEqualRects(rectOf(res, @"B"), NSMakeRect(0, 0, 1920, 1080))
             && NSEqualRects(rectOf(res, kPrimaryName),
                             NSMakeRect(0, 1080, 1920, 1080)),
             "a drop above the primary stacks the outputs vertically");
        PASS(startsAtOrigin(res), "the arrangement is shifted to start at 0,0");

        /* Different heights: top edges snap, a far offset stays. */
        [p setObject:R(0, 0, 2560, 1440) forKey:kPrimaryName];
        [p setObject:R(2560, 30, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 50);
        PASS(NSMinY(rectOf(res, @"B")) == 0, "a near top edge is aligned");
        [p setObject:R(2560, 200, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 50);
        PASS(NSMinY(rectOf(res, @"B")) == 200 && NSMinX(rectOf(res, @"B")) == 2560,
             "an offset beyond the snap distance is kept");

        /* Three in a row, the middle one moved below: the gap closes. */
        [p removeAllObjects];
        [p setObject:R(0, 0, 1920, 1080) forKey:kPrimaryName];
        [p setObject:R(100, 1300, 1920, 1080) forKey:@"B"];
        [p setObject:R(3840, 0, 1920, 1080) forKey:@"C"];
        res = DisplayArrangeRects(p, kPrimaryName, @"B", 50);
        PASS(overlapsNone(res), "three outputs: no overlaps");
        PASS(connected(res), "three outputs: no gaps, all touch");
        PASS(NSEqualRects(rectOf(res, @"C"), NSMakeRect(1920, 0, 1920, 1080)),
             "the output beyond the removed middle one moves up to close the gap");
        PASS(NSMinY(rectOf(res, @"B")) == 1080, "the moved output sits below");

        /* Primary moved to the far right. */
        [p removeAllObjects];
        [p setObject:R(0, 0, 1920, 1080) forKey:kPrimaryName];
        [p setObject:R(1920, 0, 1920, 1080) forKey:@"B"];
        [p setObject:R(3900, 0, 1920, 1080) forKey:kPrimaryName];
        res = DisplayArrangeRects(p, kPrimaryName, kPrimaryName, 100);
        PASS(NSEqualRects(rectOf(res, @"B"), NSMakeRect(0, 0, 1920, 1080))
             && NSEqualRects(rectOf(res, kPrimaryName),
                             NSMakeRect(1920, 0, 1920, 1080)),
             "the primary moved right of the other output");

        /* A resized output with nothing moved: overlaps resolved. */
        [p removeAllObjects];
        [p setObject:R(0, 0, 2560, 1440) forKey:kPrimaryName];
        [p setObject:R(1920, 0, 1920, 1080) forKey:@"B"];
        res = DisplayArrangeRects(p, kPrimaryName, nil, 50);
        PASS(NSEqualRects(rectOf(res, @"B"), NSMakeRect(2560, 0, 1920, 1080)),
             "an output overlapped by a grown neighbor is pushed aside");
    }
    END_SET("arrangement: no overlaps, no gaps, vertical placement")

    START_SET("view mapping")
    {
        NSRect model = NSMakeRect(0, 0, 3840, 1080);
        DisplayViewMapping m = DisplayViewMappingMake(model,
            NSMakeRect(0, 0, 400, 200), 10, 0.25);
        PASS(EQ(m.scale, 380.0 / 3840.0), "the view scale fits the width");
        NSRect right = DisplayViewRectForModelRect(NSMakeRect(1920, 0, 1920, 1080), m);
        NSPoint back = DisplayModelOriginForViewRect(right, m);
        PASS(NSEqualPoints(back, NSMakePoint(1920, 0)),
             "model -> view -> model round trip");

        NSRect lower = DisplayViewRectForModelRect(NSMakeRect(0, 1080, 1920, 1080),
            DisplayViewMappingMake(NSMakeRect(0, 0, 1920, 2160),
                                   NSMakeRect(0, 0, 400, 200), 10, 0.25));
        NSRect upper = DisplayViewRectForModelRect(NSMakeRect(0, 0, 1920, 1080),
            DisplayViewMappingMake(NSMakeRect(0, 0, 1920, 2160),
                                   NSMakeRect(0, 0, 400, 200), 10, 0.25));
        PASS(NSMinY(lower) < NSMinY(upper),
             "the view is y-up: an output below on the screen is lower in the view");

        NSRect dragged = NSOffsetRect(right, 0, 1080 * m.scale);
        PASS(NSEqualPoints(DisplayModelOriginForViewRect(dragged, m),
                           NSMakePoint(1920, -1080)),
             "dragging up in the view moves the output up on the screen");
    }
    END_SET("view mapping")

    START_SET("screen size: grow first, then shrink")
    {
        NSArray *frames = [NSArray arrayWithObjects:R(0, 0, 1920, 1080),
                           R(1920, 0, 2560, 1440), nil];
        DisplayScreenSizePlan plan = DisplayPlanScreenSize(NSMakeSize(1920, 1080), frames);
        PASS(NSEqualSizes(plan.grow, NSMakeSize(4480, 1440))
             && NSEqualSizes(plan.final, NSMakeSize(4480, 1440)),
             "adding an output grows the screen before the CRTC is set");

        frames = [NSArray arrayWithObject:R(0, 0, 1280, 1024)];
        plan = DisplayPlanScreenSize(NSMakeSize(4480, 1440), frames);
        PASS(NSEqualSizes(plan.grow, NSMakeSize(4480, 1440))
             && NSEqualSizes(plan.final, NSMakeSize(1280, 1024)),
             "a smaller layout keeps the screen until the CRTCs moved, then shrinks");

        frames = [NSArray arrayWithObject:R(0, 0, 1920, 1080)];
        plan = DisplayPlanScreenSize(NSMakeSize(1024, 768), frames);
        PASS(NSEqualSizes(plan.grow, NSMakeSize(1920, 1080)),
             "a larger mode grows the screen first");

        frames = [NSArray arrayWithObjects:R(0, 0, 2560, 1440),
                  R(2560, 0, 1920, 1080), nil];
        plan = DisplayPlanScreenSize(NSMakeSize(3840, 1080), frames);
        PASS(NSEqualSizes(plan.grow, NSMakeSize(4480, 1440))
             && NSEqualSizes(plan.final, NSMakeSize(4480, 1440)),
             "growing in one direction while shrinking in none");
    }
    END_SET("screen size: grow first, then shrink")

    START_SET("CRTC assignment")
    {
        NSString *failed = nil;
        NSArray *req = [NSArray arrayWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys:@"A", @"name", @0x40, @"crtc",
                [NSArray arrayWithObjects:@0x40, @0x41, nil], @"possible", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"B", @"name", @0, @"crtc",
                [NSArray arrayWithObjects:@0x40, @0x41, nil], @"possible", nil],
            nil];
        NSDictionary *res = DisplayAssignCrtcs(req, &failed);
        PASS([[res objectForKey:@"A"] intValue] == 0x40, "an output keeps its CRTC");
        PASS([[res objectForKey:@"B"] intValue] == 0x41,
             "a newly connected output gets a free CRTC it can drive");

        req = [NSArray arrayWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys:@"A", @"name", @0x40, @"crtc",
                [NSArray arrayWithObjects:@0x40, nil], @"possible", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"B", @"name", @0, @"crtc",
                [NSArray arrayWithObjects:@0x40, nil], @"possible", nil],
            nil];
        failed = nil;
        res = DisplayAssignCrtcs(req, &failed);
        PASS(res == nil && [failed isEqualToString:@"B"],
             "no free CRTC the output can drive: refused, naming the output");

        req = [NSArray arrayWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys:@"A", @"name", @0x40, @"crtc",
                [NSArray arrayWithObjects:@0x40, @0x41, nil], @"possible", nil],
            [NSDictionary dictionaryWithObjectsAndKeys:@"B", @"name", @0x40, @"crtc",
                [NSArray arrayWithObjects:@0x40, @0x41, nil], @"possible", nil],
            nil];
        res = DisplayAssignCrtcs(req, &failed);
        PASS([[res objectForKey:@"A"] intValue] == 0x40
             && [[res objectForKey:@"B"] intValue] == 0x41,
             "two outputs sharing a CRTC get one each");
    }
    END_SET("CRTC assignment")

    START_SET("scale factor range")
    {
        PASS(EQ(DisplayClampScaleFactor(3.0), 3.0), "3.0 is accepted");
        PASS(EQ(DisplayClampScaleFactor(3.4), 3.0), "above 3.0 is clamped");
        PASS(EQ(DisplayClampScaleFactor(0.5), 0.8), "below 0.8 is clamped");
        PASS(EQ(DisplayClampScaleFactor(2.47), 2.5), "rounded to one decimal");
    }
    END_SET("scale factor range")

    [arp release];
    return 0;
}
