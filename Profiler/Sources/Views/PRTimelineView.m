/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRTimelineView.h"
#import "PRAppearance.h"

@implementation PRTimelineView

@synthesize costUnit = _costUnit;
@synthesize frequency = _frequency;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;
    _frequency = 999;
    [self clear];
    return self;
}

- (void)clear
{
    _values = nil;
    _curve = nil;
    _startTime = 0;
    _endTime = 0;
    _caption = nil;
    [self clearSelection];
    [self setNeedsDisplay:YES];
}

- (void)setBuckets:(NSArray *)values
         startTime:(double)startTime
           endTime:(double)endTime
{
    _values = [values copy];
    _curve = nil;
    _startTime = startTime;
    _endTime = endTime;
    _caption = nil;
    [self clearSelection];
    [self setNeedsDisplay:YES];
}

- (void)setCurve:(NSArray *)points caption:(NSString *)caption
{
    _curve = [points copy];
    _values = nil;
    _caption = [caption copy];
    _startTime = 0;
    _endTime = 0;
    for (NSDictionary *point in _curve) {
        double time = [[point objectForKey:@"time"] doubleValue];
        if (time > _endTime)
            _endTime = time;
    }
    [self clearSelection];
    [self setNeedsDisplay:YES];
}

- (void)clearSelection
{
    _selectionStart = 0;
    _selectionEnd = 0;
    [self setNeedsDisplay:YES];
}

- (PRTimeRange)selectedRange
{
    PRTimeRange range;
    if (_selectionEnd <= _selectionStart)
        return PRTimeRangeAll();
    range.start = _selectionStart;
    range.end = _selectionEnd;
    return range;
}

- (BOOL)hasData
{
    /* A recording that lasted no measurable time has nothing to plot. */
    if (_endTime <= _startTime)
        return NO;
    return [_values count] > 1 || [_curve count] > 1;
}

- (double)timeForX:(CGFloat)x
{
    CGFloat width = NSWidth([self bounds]);
    if (width <= 0 || _endTime <= _startTime)
        return _startTime;
    double fraction = x / width;
    if (fraction < 0) fraction = 0;
    if (fraction > 1) fraction = 1;
    return _startTime + fraction * (_endTime - _startTime);
}

- (CGFloat)xForTime:(double)time
{
    if (_endTime <= _startTime)
        return 0;
    return (CGFloat)((time - _startTime) / (_endTime - _startTime)) *
           NSWidth([self bounds]);
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRect bounds = [self bounds];

    [[NSColor colorWithCalibratedWhite:0.99 alpha:1.0] set];
    NSRectFill(bounds);

    if (![self hasData]) {
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor darkGrayColor]
        };
        [(_values == nil && _curve == nil ? @"No recording yet" :
          @"The recording was too short to show a curve")
         drawAtPoint:NSMakePoint(6, NSHeight(bounds) / 2 - 6)
                          withAttributes:attributes];
        [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] set];
        NSFrameRectWithWidth(bounds, 1.0);
        return;
    }

    CGFloat inset = 2.0;
    NSRect plot = NSInsetRect(bounds, inset, inset);
    double peak = 0;

    if (_values != nil) {
        for (NSNumber *value in _values)
            if ([value doubleValue] > peak)
                peak = [value doubleValue];
    } else {
        for (NSDictionary *point in _curve) {
            double value = [[point objectForKey:@"value"] doubleValue];
            if (value > peak)
                peak = value;
        }
    }
    if (peak <= 0)
        peak = 1;

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMinX(plot), NSMinY(plot))];

    if (_values != nil) {
        NSUInteger count = [_values count];
        for (NSUInteger i = 0; i < count; i++) {
            double value = [[_values objectAtIndex:i] doubleValue];
            CGFloat x = NSMinX(plot) + NSWidth(plot) * ((CGFloat)i / (CGFloat)(count - 1));
            CGFloat y = NSMinY(plot) + NSHeight(plot) * (CGFloat)(value / peak);
            [path lineToPoint:NSMakePoint(x, y)];
        }
    } else {
        double span = _endTime - _startTime;
        if (span <= 0)
            span = 1;
        for (NSDictionary *point in _curve) {
            double time = [[point objectForKey:@"time"] doubleValue];
            double value = [[point objectForKey:@"value"] doubleValue];
            CGFloat x = NSMinX(plot) +
                        NSWidth(plot) * (CGFloat)((time - _startTime) / span);
            CGFloat y = NSMinY(plot) + NSHeight(plot) * (CGFloat)(value / peak);
            [path lineToPoint:NSMakePoint(x, y)];
        }
    }

    [path lineToPoint:NSMakePoint(NSMaxX(plot), NSMinY(plot))];
    [path closePath];

    [[NSColor colorWithCalibratedRed:0.30 green:0.55 blue:0.85 alpha:0.35] set];
    [path fill];
    [[NSColor colorWithCalibratedRed:0.20 green:0.42 blue:0.72 alpha:0.9] set];
    [path setLineWidth:1.0];
    [path stroke];

    if (_selectionEnd > _selectionStart) {
        NSRect selection = NSMakeRect([self xForTime:_selectionStart],
                                      NSMinY(bounds),
                                      [self xForTime:_selectionEnd] -
                                      [self xForTime:_selectionStart],
                                      NSHeight(bounds));
        [[NSColor colorWithCalibratedRed:0.95 green:0.75 blue:0.25 alpha:0.30] set];
        NSRectFillUsingOperation(selection, NSCompositeSourceOver);
        [[NSColor colorWithCalibratedRed:0.80 green:0.55 blue:0.10 alpha:0.9] set];
        NSFrameRectWithWidth(selection, 1.0);
    }

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor darkGrayColor]
    };
    NSString *left = _caption ? _caption : @"0 s";
    NSString *right = [NSString stringWithFormat:@"%.1f s", _endTime - _startTime];
    [left drawAtPoint:NSMakePoint(4, 2) withAttributes:attributes];
    NSSize size = [right sizeWithAttributes:attributes];
    [right drawAtPoint:NSMakePoint(NSMaxX(bounds) - size.width - 4, 2)
        withAttributes:attributes];

    [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] set];
    NSFrameRectWithWidth(bounds, 1.0);
}

- (void)mouseDown:(NSEvent *)event
{
    if (![self hasData] || _curve != nil)
        return;

    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    _dragAnchor = [self timeForX:point.x];
    _selectionStart = _dragAnchor;
    _selectionEnd = _dragAnchor;
    _dragging = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_dragging)
        return;

    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    double time = [self timeForX:point.x];
    _selectionStart = MIN(_dragAnchor, time);
    _selectionEnd = MAX(_dragAnchor, time);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
    (void)event;
    if (!_dragging)
        return;
    _dragging = NO;

    /* A click without dragging means "show everything again". */
    if (_selectionEnd - _selectionStart < (_endTime - _startTime) / 200.0)
        [self clearSelection];

    [self setNeedsDisplay:YES];
    if ([[self delegate] respondsToSelector:@selector(timelineView:didSelectRange:)])
        [[self delegate] timelineView:self didSelectRange:[self selectedRange]];
}

@end
