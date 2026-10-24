/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "AccelerationCurve.h"
#include <math.h>

const NSUInteger AccelerationCurvePointCount = 64;
const double AccelerationMouseUnitsPerMM = 1000.0 / 25.4;

/* libinput's built-in profiles and its custom profile's output are in
   1000 dpi units, so gains everywhere in the pane use this unit. */
static const double kNormalizedUnitsPerMM = 1000.0 / 25.4;

/* Sampling a quarter beyond the graph keeps the last two points in the
   constant-gain part of the curve, so libinput's linear extrapolation for
   faster motion stays exact. */
static const double kSampledRange = 1.25;

/* libinput 1.28 filter-touchpad.c and filter-touchpad-flat.c. */
static const double kTouchpadMagicSlowdown = 0.2968;
static const double kTouchpadThreshold = 130.0;      /* mm/s */
static const double kTouchpadBaseline = 0.9;

/* libinput 1.28 filter-mouse.c, in 1000 dpi units per millisecond. */
static const double kMouseThreshold = 0.4;
static const double kMouseMinimumThreshold = 0.2;
static const double kMouseAcceleration = 2.0;
static const double kMouseIncline = 1.1;
static const double kMouseDecelerationEnd = 0.07;

static BOOL IsTouchpad(PointerDeviceKind kind)
{
    return kind == PointerDeviceKindTouchpad;
}

double AccelerationCurveMaxSpeed(PointerDeviceKind kind)
{
    /* 750 mm/s puts the touchpad defaults' start and end (20% and 70%) at
       150 and 525 mm/s, close to where libinput's touchpad profile starts
       (130 mm/s) and stops (4 x 130 mm/s) accelerating.  A mouse profile
       has done all its accelerating by ~40 mm/s. */
    return IsTouchpad(kind) ? 750.0 : 100.0;
}

double AccelerationCurveMaxGain(PointerDeviceKind kind)
{
    /* The fastest mouse speed setting reaches 3.5x; touchpad gains carry
       libinput's slowdown and stay well below 2. */
    return IsTouchpad(kind) ? 2.0 : 4.0;
}

AccelerationCurve AccelerationCurveDefaults(PointerDeviceKind kind)
{
    AccelerationCurve c;
    if (IsTouchpad(kind)) {
        c.precision = 0.30;
        c.start = 0.20;
        c.end = 0.70;
        c.fast = 1.60;
    } else {
        c.precision = 1.0;
        c.start = 0.10;
        c.end = 0.35;
        c.fast = 2.0;
    }
    return c;
}

BOOL AccelerationCurveEqualToCurve(AccelerationCurve a, AccelerationCurve b)
{
    return a.precision == b.precision && a.start == b.start
        && a.end == b.end && a.fast == b.fast;
}

double AccelerationCurveGain(AccelerationCurve curve, double position)
{
    double t;
    if (curve.end <= curve.start) {
        t = (position <= curve.start) ? 0.0 : 1.0;
    } else {
        t = (position - curve.start) / (curve.end - curve.start);
    }
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    /* Hermite interpolation gives a smooth S-curve between the two gains. */
    return curve.precision + (curve.fast - curve.precision) * t * t * (3.0 - 2.0 * t);
}

double AccelerationCurvePointStep(PointerDeviceKind kind, double unitsPerMM)
{
    return AccelerationCurveMaxSpeed(kind) * kSampledRange * unitsPerMM / 1000.0
        / (AccelerationCurvePointCount - 1);
}

NSArray *AccelerationCurvePoints(PointerDeviceKind kind, AccelerationCurve curve, double unitsPerMM)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:AccelerationCurvePointCount];
    double step = AccelerationCurvePointStep(kind, unitsPerMM);
    double maxUnits = AccelerationCurveMaxSpeed(kind) * unitsPerMM / 1000.0;
    /* The custom profile takes raw device units but its output is used as
       1000 dpi units, so the gain is rescaled to mean the same as in the
       built-in profiles at any resolution (a no-op for a 1000 dpi mouse). */
    double scale = kNormalizedUnitsPerMM / unitsPerMM;
    for (NSUInteger i = 0; i < AccelerationCurvePointCount; i++) {
        double speed = i * step;
        double gain = AccelerationCurveGain(curve, speed / maxUnits);
        [out addObject:[NSNumber numberWithDouble:speed * gain * scale]];
    }
    return out;
}

/* ---- Touchpad profiles ---- */

static double TouchpadSpeedFactor(double speedSetting)
{
    return pow(speedSetting + 1.0, 2.38) * 0.95 + 0.05;
}

static double TouchpadAdaptiveGain(double speedSetting, double mmPerSecond)
{
    double factor;
    if (mmPerSecond < 7.0) {
        factor = MIN(kTouchpadBaseline, 0.1 * mmPerSecond + 0.3);
    } else if (mmPerSecond < kTouchpadThreshold) {
        factor = kTouchpadBaseline;
    } else {
        double v = MIN(mmPerSecond, 4.0 * kTouchpadThreshold);
        factor = 0.0025 * (v / kTouchpadThreshold) * (v - kTouchpadThreshold)
            + kTouchpadBaseline;
    }
    return factor * TouchpadSpeedFactor(speedSetting) * kTouchpadMagicSlowdown;
}

/* ---- Mouse profile ---- */

typedef struct {
    double threshold;   /* 1000 dpi units per ms */
    double maxGain;
    double incline;
} MouseAdaptive;

static MouseAdaptive MouseAdaptiveForSpeed(double speedSetting)
{
    MouseAdaptive m;
    m.threshold = MAX(kMouseMinimumThreshold, kMouseThreshold - 0.25 * speedSetting);
    m.maxGain = kMouseAcceleration + 1.5 * speedSetting;
    m.incline = kMouseIncline + 0.75 * speedSetting;
    return m;
}

static double MouseAdaptiveGain(double speedSetting, double mmPerSecond)
{
    MouseAdaptive m = MouseAdaptiveForSpeed(speedSetting);
    double v = mmPerSecond * kNormalizedUnitsPerMM / 1000.0;
    double factor;
    if (v < kMouseDecelerationEnd) {
        factor = 10.0 * v + 0.3;
    } else if (v < m.threshold) {
        factor = 1.0;
    } else {
        factor = m.incline * (v - m.threshold) + 1.0;
    }
    return MIN(m.maxGain, factor);
}

static double AdaptiveGain(PointerDeviceKind kind, double speedSetting, double mmPerSecond)
{
    return IsTouchpad(kind) ? TouchpadAdaptiveGain(speedSetting, mmPerSecond)
                            : MouseAdaptiveGain(speedSetting, mmPerSecond);
}

AccelerationCurve AccelerationAdaptiveCurve(PointerDeviceKind kind, double speedSetting)
{
    double maxSpeed = AccelerationCurveMaxSpeed(kind);
    AccelerationCurve c;
    if (IsTouchpad(kind)) {
        c.precision = TouchpadAdaptiveGain(speedSetting, kTouchpadThreshold / 2.0);
        c.start = kTouchpadThreshold / maxSpeed;
        c.end = 4.0 * kTouchpadThreshold / maxSpeed;
        c.fast = TouchpadAdaptiveGain(speedSetting, 4.0 * kTouchpadThreshold);
    } else {
        MouseAdaptive m = MouseAdaptiveForSpeed(speedSetting);
        double mmPerUnitMs = 1000.0 / kNormalizedUnitsPerMM;
        c.precision = 1.0;
        c.start = m.threshold * mmPerUnitMs / maxSpeed;
        c.end = (m.threshold + (m.maxGain - 1.0) / m.incline) * mmPerUnitMs / maxSpeed;
        c.fast = m.maxGain;
    }
    return c;
}

NSArray *AccelerationAdaptiveGains(PointerDeviceKind kind, double speedSetting, NSUInteger count)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    double maxSpeed = AccelerationCurveMaxSpeed(kind);
    for (NSUInteger i = 0; i < count; i++) {
        double position = (double)i / (count - 1);
        [out addObject:[NSNumber numberWithDouble:
            AdaptiveGain(kind, speedSetting, position * maxSpeed)]];
    }
    return out;
}

double AccelerationFlatGain(PointerDeviceKind kind, double speedSetting)
{
    double gain = MAX(0.005, 1.0 + speedSetting);
    return IsTouchpad(kind) ? gain * kTouchpadMagicSlowdown : gain;
}
