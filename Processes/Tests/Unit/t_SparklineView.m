/* t_SparklineView.m - ObjectTesting coverage for the sparkline mapping.
 * Headless: only the point mapping is exercised, never the drawing.
 *
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SparklineView.h"

static NSString * const kToolDescription = @"SparklineView mapping tests";

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSRect plot = NSMakeRect(0.0, 0.0, 100.0, 50.0);

    /* --- nothing to plot --- */
    {
        SparklineView *view = [[SparklineView alloc] initWithFrame: plot];
        PASS([[view plotPointsInRect: plot] count] == 0, "no samples, no points");
        [view setValues: [NSArray arrayWithObject: [NSNumber numberWithDouble: 5.0]]];
        PASS([[view plotPointsInRect: plot] count] == 1, "a single sample is one point");
        [view release];
    }

    /* --- the samples span the full width, oldest on the left --- */
    {
        SparklineView *view = [[SparklineView alloc] initWithFrame: plot];
        NSArray *values = [NSArray arrayWithObjects:
                              [NSNumber numberWithDouble: 0.0],
                              [NSNumber numberWithDouble: 5.0],
                              [NSNumber numberWithDouble: 10.0], nil];
        [view setValues: values];
        NSArray *points = [view plotPointsInRect: plot];
        PASS([points count] == 3, "one point per sample");
        NSPoint first = [[points objectAtIndex: 0] pointValue];
        NSPoint middle = [[points objectAtIndex: 1] pointValue];
        NSPoint last = [[points objectAtIndex: 2] pointValue];
        PASS(first.x == 0.0, "the oldest sample sits on the left edge");
        PASS(last.x == 100.0, "the newest sample sits on the right edge");
        PASS(middle.x > first.x && middle.x < last.x, "the samples are evenly spread");
        PASS(first.y == 0.0, "the smallest sample sits on the bottom");
        PASS(last.y == 50.0, "the largest sample reaches the top");
        PASS(middle.y > 24.0 && middle.y < 26.0, "half the value is half the height");
        [view release];
    }

    /* --- a fixed scale is honored --- */
    {
        SparklineView *view = [[SparklineView alloc] initWithFrame: plot];
        [view setMaximum: 100.0];
        [view setValues: [NSArray arrayWithObjects:
                             [NSNumber numberWithDouble: 25.0],
                             [NSNumber numberWithDouble: 50.0], nil]];
        NSArray *points = [view plotPointsInRect: plot];
        NSPoint first = [[points objectAtIndex: 0] pointValue];
        NSPoint last = [[points objectAtIndex: 1] pointValue];
        PASS(first.y > 12.0 && first.y < 13.0, "a quarter of the scale is a quarter up");
        PASS(last.y > 24.0 && last.y < 26.0, "half the scale is half up");
        [view release];
    }

    /* --- a flat line does not divide by zero --- */
    {
        SparklineView *view = [[SparklineView alloc] initWithFrame: plot];
        [view setValues: [NSArray arrayWithObjects:
                             [NSNumber numberWithDouble: 7.0],
                             [NSNumber numberWithDouble: 7.0], nil]];
        NSArray *points = [view plotPointsInRect: plot];
        NSPoint first = [[points objectAtIndex: 0] pointValue];
        PASS(first.y >= 0.0 && first.y <= 50.0, "a constant value stays inside the plot");
        [view release];
    }

    NSLog(@"%@ done", kToolDescription);
    [arp release];
    return 0;
}
