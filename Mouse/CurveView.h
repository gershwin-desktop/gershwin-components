/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

#import "AccelerationCurve.h"

@class CurveView;

@protocol CurveViewDelegate <NSObject>
@optional
- (void)curveViewDidChange:(CurveView *)curveView;
@end

@interface CurveView : NSView
{
    AccelerationCurve _curve;
    double _maximum;
    double _maxSpeed;
    NSInteger _dragHandle;     /* -1 = none, 0 = precision, 1 = start, 2 = end, 3 = fast */
    NSPoint _dragStart;
    id<CurveViewDelegate> _delegate;
}

@property (nonatomic) AccelerationCurve curve;
@property (nonatomic) double maximum;
/* The speed at the right edge of the graph, in mm/s, for the axis labels. */
@property (nonatomic) double maxSpeed;
@property (nonatomic, assign) id<CurveViewDelegate> delegate;
@property (nonatomic) BOOL curveEnabled;
/* A built-in profile's curve cannot be expressed by the four parameters, so
   it is drawn from gains sampled at evenly spaced speeds instead. */
@property (nonatomic, copy) NSArray *displayedGains;
/* Flat accelerates nowhere, so its Start and End handles would mislead. */
@property (nonatomic) BOOL showsRange;

- (NSRect)rectForHandle:(NSInteger)handle;
- (void)setNeedsDisplayForHandle:(NSInteger)handle;

@end
