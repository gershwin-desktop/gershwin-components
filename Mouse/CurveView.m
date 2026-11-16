/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CurveView.h"
#include <math.h>

/* Handle radius in points */
static const double kHandleRadius = 6.0;

/* Padding around the graph area */
static const double kGraphPaddingLeft   = 36.0;
static const double kGraphPaddingRight  = 12.0;
static const double kGraphPaddingTop    = 8.0;
static const double kGraphPaddingBottom = 22.0;

@implementation CurveView

@synthesize curve = _curve;
@synthesize maximum = _maximum;
@synthesize maxSpeed = _maxSpeed;
@synthesize delegate = _delegate;
@synthesize curveEnabled = _curveEnabled;
@synthesize displayedGains = _displayedGains;
@synthesize showsRange = _showsRange;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _curve = AccelerationCurveDefaults(PointerDeviceKindTouchpad);
        _maximum = AccelerationCurveMaxGain(PointerDeviceKindTouchpad);
        _maxSpeed = AccelerationCurveMaxSpeed(PointerDeviceKindTouchpad);
        _dragHandle = -1;
        _curveEnabled = YES;
        _showsRange = YES;
    }
    return self;
}

- (void)dealloc
{
    [_displayedGains release];
    [super dealloc];
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    (void)event;
    return YES;
}

/* ---- Coordinate conversion ---- */

- (NSRect)graphRect
{
    NSRect b = [self bounds];
    /* The view is flipped, so the top padding is the one at the origin. */
    return NSMakeRect(
        kGraphPaddingLeft,
        kGraphPaddingTop,
        b.size.width - kGraphPaddingLeft - kGraphPaddingRight,
        b.size.height - kGraphPaddingTop - kGraphPaddingBottom
    );
}

- (double)gainForY:(CGFloat)y
{
    NSRect g = [self graphRect];
    double fraction = 1.0 - (y - g.origin.y) / g.size.height;
    if (fraction < 0.0) fraction = 0.0;
    if (fraction > 1.0) fraction = 1.0;
    return fraction * _maximum;
}

- (CGFloat)yForGain:(double)gain
{
    NSRect g = [self graphRect];
    return g.origin.y + g.size.height * (1.0 - gain / _maximum);
}

- (double)positionForX:(CGFloat)x
{
    NSRect g = [self graphRect];
    double fraction = (x - g.origin.x) / g.size.width;
    if (fraction < 0.0) fraction = 0.0;
    if (fraction > 1.0) fraction = 1.0;
    return fraction;
}

- (CGFloat)xForPosition:(double)position
{
    NSRect g = [self graphRect];
    return g.origin.x + g.size.width * position;
}

/* ---- Handle rectangles ---- */

- (NSRect)rectForHandle:(NSInteger)handle
{
    NSRect g = [self graphRect];
    CGFloat cx, cy;
    double radius = kHandleRadius;

    if (handle == 0) {
        /* Precision: left side, gain = curve.precision */
        cx = g.origin.x;
        cy = [self yForGain:_curve.precision];
    } else if (handle == 1) {
        /* Start: bottom edge, position = curve.start */
        cx = [self xForPosition:_curve.start];
        cy = g.origin.y + g.size.height;
    } else if (handle == 2) {
        /* End: bottom edge, position = curve.end */
        cx = [self xForPosition:_curve.end];
        cy = g.origin.y + g.size.height;
    } else {
        /* Fast swipes: right side, gain = curve.fast */
        cx = g.origin.x + g.size.width;
        cy = [self yForGain:_curve.fast];
    }
    return NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2);
}

/* ---- Drawing ---- */

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRect g = [self graphRect];
    NSColor *accent = [NSColor colorWithCalibratedRed:0.2 green:0.45 blue:0.8 alpha:1.0];
    /* Grey handles tell that a built-in profile's parameters are shown, not
       editable. */
    NSColor *handleColor = _curveEnabled ? accent : [NSColor grayColor];

    /* Fill graph background */
    [[NSColor colorWithCalibratedWhite:0.97 alpha:1.0] set];
    NSRectFill(g);

    /* Grid lines */
    [[NSColor colorWithCalibratedWhite:0.85 alpha:1.0] set];
    NSBezierPath *grid = [NSBezierPath bezierPath];

    /* Vertical grid lines at 0%, 25%, 50%, 75%, 100% */
    for (int i = 0; i <= 4; i++) {
        CGFloat x = g.origin.x + g.size.width * i / 4.0;
        [grid moveToPoint:NSMakePoint(x, g.origin.y)];
        [grid lineToPoint:NSMakePoint(x, g.origin.y + g.size.height)];
    }

    /* Horizontal grid lines at evenly spaced gain values */
    int hLines = 4;
    for (int i = 0; i <= hLines; i++) {
        CGFloat y = g.origin.y + g.size.height * i / (double)hLines;
        [grid moveToPoint:NSMakePoint(g.origin.x, y)];
        [grid lineToPoint:NSMakePoint(g.origin.x + g.size.width, y)];
    }
    [grid stroke];

    /* Axis labels */
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor grayColor]
    };

    /* Y-axis labels: 0, max/2, max */
    NSString *yLabels[3];
    yLabels[0] = @"0";
    yLabels[1] = [NSString stringWithFormat:@"%.1f", _maximum / 2.0];
    yLabels[2] = [NSString stringWithFormat:@"%.1f", _maximum];
    for (int i = 0; i < 3; i++) {
        CGFloat y = g.origin.y + g.size.height * (2 - i) / 2.0;
        NSSize sz = [yLabels[i] sizeWithAttributes:labelAttrs];
        [yLabels[i] drawAtPoint:NSMakePoint(g.origin.x - sz.width - 4, y - sz.height / 2)
                 withAttributes:labelAttrs];
    }

    /* X-axis labels in finger speed, the unit the Start and End values use */
    NSString *xLabels[3];
    xLabels[0] = @"0";
    xLabels[1] = [NSString stringWithFormat:@"%.0f", _maxSpeed / 2.0];
    xLabels[2] = [NSString stringWithFormat:@"%.0f mm/s", _maxSpeed];
    for (int i = 0; i < 3; i++) {
        CGFloat x = g.origin.x + g.size.width * i / 2.0;
        NSSize sz = [xLabels[i] sizeWithAttributes:labelAttrs];
        /* The outer labels align to the graph edges so the view does not
           clip the unit. */
        CGFloat lx = (i == 0) ? x : (i == 1) ? x - sz.width / 2 : x - sz.width;
        /* 8 keeps the labels clear of the Start and End handles, which sit
           on the axis. */
        [xLabels[i] drawAtPoint:NSMakePoint(lx, g.origin.y + g.size.height + 8)
                 withAttributes:labelAttrs];
    }

    /* Draw the acceleration curve */
    [accent set];
    NSBezierPath *curvePath = [NSBezierPath bezierPath];
    BOOL first = YES;
    NSUInteger samples = _displayedGains ? [_displayedGains count] : 101;
    for (NSUInteger i = 0; i < samples; i++) {
        double speed = (double)i / (samples - 1);
        double gain = _displayedGains
            ? [[_displayedGains objectAtIndex:i] doubleValue]
            : AccelerationCurveGain(_curve, speed);
        CGFloat x = [self xForPosition:speed];
        CGFloat y = [self yForGain:gain];
        if (first) {
            [curvePath moveToPoint:NSMakePoint(x, y)];
            first = NO;
        } else {
            [curvePath lineToPoint:NSMakePoint(x, y)];
        }
    }
    [curvePath setLineWidth:2.0];
    [curvePath stroke];

    /* Draw the handles */
    for (NSInteger i = 0; i < 4; i++) {
        if (!_showsRange && (i == 1 || i == 2)) {
            continue;
        }
        NSRect hr = [self rectForHandle:i];
        if (i == _dragHandle) {
            /* Highlighted handle */
            [[NSColor colorWithCalibratedRed:0.2 green:0.45 blue:0.8 alpha:0.3] set];
            NSRectFill(NSInsetRect(hr, -2, -2));
            [handleColor set];
            NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:hr];
            [circle setLineWidth:2.0];
            [circle stroke];
            [[NSColor whiteColor] set];
            NSRectFill(NSInsetRect(hr, 2, 2));
        } else {
            [[NSColor whiteColor] set];
            NSBezierPath *circle;
            if (i == 1 || i == 2) {
                /* Start/end: square handles */
                circle = [NSBezierPath bezierPathWithRect:hr];
            } else {
                /* Precision/fast: round handles */
                circle = [NSBezierPath bezierPathWithOvalInRect:hr];
            }
            [handleColor set];
            [circle setLineWidth:2.0];
            [circle stroke];
            [[NSColor whiteColor] set];
            NSRectFill(NSInsetRect(hr, 1.5, 1.5));
        }
    }
}

/* ---- Mouse interaction ---- */

- (NSInteger)handleAtPoint:(NSPoint)point
{
    /* Check in reverse order so top-most handle wins */
    for (NSInteger i = 3; i >= 0; i--) {
        if (!_showsRange && (i == 1 || i == 2)) {
            continue;
        }
        NSRect hr = [self rectForHandle:i];
        /* Expand hit area slightly */
        NSRect hit = NSInsetRect(hr, -5, -5);
        if (NSPointInRect(point, hit)) {
            return i;
        }
    }
    return -1;
}

- (void)mouseDown:(NSEvent *)event
{
    if (!_curveEnabled) return;
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    _dragHandle = [self handleAtPoint:point];
    if (_dragHandle >= 0) {
        _dragStart = point;
        [self setNeedsDisplayForHandle:_dragHandle];
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    if (_dragHandle < 0) return;

    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    AccelerationCurve next = _curve;

    if (_dragHandle == 0) {
        /* Precision: drag vertically */
        double gain = [self gainForY:point.y];
        if (gain < 0.01) gain = 0.01;
        if (gain > _maximum) gain = _maximum;
        next.precision = gain;
        if (next.precision > next.fast) next.fast = next.precision;
    } else if (_dragHandle == 1) {
        /* Start: drag horizontally */
        double pos = [self positionForX:point.x];
        if (pos < 0.0) pos = 0.0;
        if (pos > next.end - 0.02) pos = next.end - 0.02;
        next.start = pos;
    } else if (_dragHandle == 2) {
        /* End: drag horizontally */
        double pos = [self positionForX:point.x];
        if (pos < next.start + 0.02) pos = next.start + 0.02;
        if (pos > 1.0) pos = 1.0;
        next.end = pos;
    } else if (_dragHandle == 3) {
        /* Fast swipes: drag vertically */
        double gain = [self gainForY:point.y];
        if (gain < next.precision) gain = next.precision;
        if (gain > _maximum) gain = _maximum;
        next.fast = gain;
    }

    _curve = next;
    [self setNeedsDisplay:YES];
    if ([_delegate respondsToSelector:@selector(curveViewDidChange:)]) {
        [_delegate curveViewDidChange:self];
    }
}

- (void)mouseUp:(NSEvent *)event
{
    (void)event;
    if (_dragHandle >= 0) {
        [self setNeedsDisplayForHandle:_dragHandle];
        _dragHandle = -1;
    }
}

- (void)setNeedsDisplayForHandle:(NSInteger)handle
{
    (void)handle;
    [self setNeedsDisplay:YES];
}

- (void)setCurve:(AccelerationCurve)curve
{
    _curve = curve;
    [self setNeedsDisplay:YES];
}

- (void)setMaximum:(double)maximum
{
    _maximum = maximum;
    [self setNeedsDisplay:YES];
}

- (void)setMaxSpeed:(double)maxSpeed
{
    _maxSpeed = maxSpeed;
    [self setNeedsDisplay:YES];
}

- (void)setCurveEnabled:(BOOL)enabled
{
    _curveEnabled = enabled;
    [self setNeedsDisplay:YES];
}

- (void)setDisplayedGains:(NSArray *)gains
{
    if (gains != _displayedGains) {
        [_displayedGains release];
        _displayedGains = [gains copy];
    }
    [self setNeedsDisplay:YES];
}

- (void)setShowsRange:(BOOL)showsRange
{
    _showsRange = showsRange;
    [self setNeedsDisplay:YES];
}

@end
