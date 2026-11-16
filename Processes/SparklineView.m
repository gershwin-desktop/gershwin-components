/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SparklineView.h"

/* Room for the caption line above the plot. */
static const CGFloat kCaptionHeight = 14.0;
static const CGFloat kPlotInset = 2.0;

@implementation SparklineView

@synthesize caption = _caption;
@synthesize valueText = _valueText;
@synthesize values = _values;
@synthesize maximum = _maximum;
@synthesize lineColor = _lineColor;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame: frame];
    if (self) {
        _values = [NSArray array];
        _lineColor = [NSColor colorWithCalibratedRed: 0.20
                                               green: 0.40
                                                blue: 0.70
                                               alpha: 1.0];
    }
    return self;
}

- (void)setValues:(NSArray *)values
{
    _values = (values != nil) ? values : [NSArray array];
    [self setNeedsDisplay: YES];
}

- (void)setCaption:(NSString *)caption
{
    _caption = caption;
    [self setNeedsDisplay: YES];
}

- (void)setValueText:(NSString *)valueText
{
    _valueText = valueText;
    [self setNeedsDisplay: YES];
}

/* The area the curve is drawn in, below the caption. */
- (NSRect)plotRect
{
    NSRect bounds = [self bounds];
    NSRect plot = NSMakeRect(NSMinX(bounds) + kPlotInset,
                             NSMinY(bounds) + kPlotInset,
                             NSWidth(bounds) - 2.0 * kPlotInset,
                             NSHeight(bounds) - kCaptionHeight - 2.0 * kPlotInset);
    if (NSHeight(plot) < 1.0) {
        plot.size.height = 1.0;
    }
    return plot;
}

- (NSArray *)plotPointsInRect:(NSRect)rect
{
    NSUInteger count = [_values count];
    NSMutableArray *points = [NSMutableArray arrayWithCapacity: count];
    if (count == 0) {
        return points;
    }

    double scale = _maximum;
    if (scale <= 0.0) {
        for (NSNumber *value in _values) {
            if ([value doubleValue] > scale) {
                scale = [value doubleValue];
            }
        }
    }
    /* A history of zeroes still has to produce a flat line, not a division. */
    if (scale <= 0.0) {
        scale = 1.0;
    }

    NSUInteger i;
    for (i = 0; i < count; i++) {
        double value = [[_values objectAtIndex: i] doubleValue];
        if (value < 0.0) {
            value = 0.0;
        }
        if (value > scale) {
            value = scale;
        }
        CGFloat x = (count == 1)
                        ? NSMaxX(rect)
                        : NSMinX(rect) + NSWidth(rect) *
                                             ((CGFloat)i / (CGFloat)(count - 1));
        CGFloat y = NSMinY(rect) + NSHeight(rect) * (CGFloat)(value / scale);
        [points addObject: [NSValue valueWithPoint: NSMakePoint(x, y)]];
    }
    return points;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = [self bounds];

    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(bounds);

    NSRect plot = [self plotRect];
    NSArray *points = [self plotPointsInRect: plot];

    if ([points count] > 1) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        NSBezierPath *area = [NSBezierPath bezierPath];
        [area moveToPoint: NSMakePoint(NSMinX(plot), NSMinY(plot))];
        NSUInteger i;
        for (i = 0; i < [points count]; i++) {
            NSPoint p = [[points objectAtIndex: i] pointValue];
            if (i == 0) {
                [line moveToPoint: p];
            } else {
                [line lineToPoint: p];
            }
            [area lineToPoint: p];
        }
        [area lineToPoint: NSMakePoint(NSMaxX(plot), NSMinY(plot))];
        [area closePath];

        [[_lineColor colorWithAlphaComponent: 0.20] setFill];
        [area fill];
        [_lineColor setStroke];
        [line setLineWidth: 1.0];
        [line stroke];
    } else if ([points count] == 1) {
        NSPoint p = [[points objectAtIndex: 0] pointValue];
        [_lineColor setStroke];
        NSBezierPath *dot = [NSBezierPath bezierPath];
        [dot moveToPoint: NSMakePoint(NSMinX(plot), p.y)];
        [dot lineToPoint: NSMakePoint(NSMaxX(plot), p.y)];
        [dot stroke];
    }

    NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize: [NSFont smallSystemFontSize]], NSFontAttributeName,
        [NSColor controlTextColor], NSForegroundColorAttributeName, nil];
    if ([_caption length] > 0) {
        [_caption drawAtPoint: NSMakePoint(NSMinX(bounds) + 2.0,
                                           NSMaxY(bounds) - kCaptionHeight)
               withAttributes: attributes];
    }
    if ([_valueText length] > 0) {
        NSSize size = [_valueText sizeWithAttributes: attributes];
        [_valueText drawAtPoint: NSMakePoint(NSMaxX(bounds) - size.width - 2.0,
                                             NSMaxY(bounds) - kCaptionHeight)
                 withAttributes: attributes];
    }

    /* NSFrameRect paints with the fill color. */
    [[NSColor colorWithCalibratedWhite: 0.60 alpha: 1.0] setFill];
    NSFrameRect(NSInsetRect(plot, -1.0, -1.0));
}

@end
