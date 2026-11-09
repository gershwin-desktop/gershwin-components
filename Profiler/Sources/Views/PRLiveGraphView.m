/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRLiveGraphView.h"

@implementation PRLiveGraphView

@synthesize caption = _caption;
@synthesize maximum = _maximum;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;
    _values = [[NSMutableArray alloc] init];
    _caption = @"";
    return self;
}

- (void)addValue:(double)value
{
    [_values addObject:[NSNumber numberWithDouble:value]];
    while ([_values count] > 120)
        [_values removeObjectAtIndex:0];
    [self setNeedsDisplay:YES];
}

- (void)clear
{
    [_values removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRect bounds = [self bounds];

    [[NSColor colorWithCalibratedWhite:0.99 alpha:1.0] set];
    NSRectFill(bounds);
    [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] set];
    NSFrameRectWithWidth(bounds, 1.0);

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor darkGrayColor]
    };
    [_caption drawAtPoint:NSMakePoint(4, NSMaxY(bounds) - 13)
           withAttributes:attributes];

    if ([_values count] < 2)
        return;

    double peak = _maximum;
    if (peak <= 0)
        for (NSNumber *value in _values)
            peak = MAX(peak, [value doubleValue]);
    if (peak <= 0)
        peak = 1;

    NSRect plot = NSInsetRect(bounds, 3, 3);
    NSBezierPath *path = [NSBezierPath bezierPath];
    NSUInteger count = [_values count];

    for (NSUInteger i = 0; i < count; i++) {
        double value = [[_values objectAtIndex:i] doubleValue];
        CGFloat x = NSMinX(plot) + NSWidth(plot) * ((CGFloat)i / (CGFloat)(count - 1));
        CGFloat y = NSMinY(plot) + NSHeight(plot) * (CGFloat)MIN(value / peak, 1.0);
        if (i == 0)
            [path moveToPoint:NSMakePoint(x, y)];
        else
            [path lineToPoint:NSMakePoint(x, y)];
    }

    [[NSColor colorWithCalibratedRed:0.20 green:0.42 blue:0.72 alpha:0.9] set];
    [path setLineWidth:1.5];
    [path stroke];
}

@end
