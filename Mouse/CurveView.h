/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

typedef struct {
    double precision;  /* gain at slow finger speeds (0.01 .. 2.0) */
    double start;      /* acceleration start, fraction of max speed (0.0 .. <end) */
    double end;        /* acceleration end, fraction of max speed (>start .. 1.0) */
    double fast;       /* gain at fast finger speeds (>=precision .. 2.0) */
} AccelerationCurve;

extern const double AccelerationCurveMaxSpeed;        /* mm/s */
extern const NSUInteger AccelerationCurvePointCount;

AccelerationCurve AccelerationCurveDefaults(void);
BOOL AccelerationCurveEqualToCurve(AccelerationCurve a, AccelerationCurve b);
double AccelerationCurveGain(AccelerationCurve curve, double speed);
double AccelerationCurvePointStep(double unitsPerMM);
NSArray *AccelerationCurvePoints(AccelerationCurve curve, double unitsPerMM);
AccelerationCurve AccelerationAdaptiveCurve(double speedSetting);
NSArray *AccelerationAdaptiveGains(double speedSetting, NSUInteger count);
double AccelerationFlatGain(double speedSetting);

@class CurveView;

@protocol CurveViewDelegate <NSObject>
@optional
- (void)curveViewDidChange:(CurveView *)curveView;
@end

@interface CurveView : NSView
{
    AccelerationCurve _curve;
    double _maximum;
    NSInteger _dragHandle;     /* -1 = none, 0 = precision, 1 = start, 2 = end, 3 = fast */
    NSPoint _dragStart;
    id<CurveViewDelegate> _delegate;
}

@property (nonatomic) AccelerationCurve curve;
@property (nonatomic) double maximum;
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
