/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "PointerDevice.h"

/* A user-drawn acceleration curve and what libinput's built-in profiles do,
 * per device class.  Mice and touchpads accelerate on very different speed
 * scales (libinput's mouse profile is at full gain by ~35 mm/s, its touchpad
 * profile only starts at 130 mm/s) and with different base gains, so every
 * function takes the class.  Foundation-only: the pane draws these and
 * gershwin-apply-settings turns the stored parameters into libinput points
 * at login. */

typedef struct {
    double precision;  /* gain at slow speeds */
    double start;      /* acceleration start, fraction of the maximum speed */
    double end;        /* acceleration end, fraction of the maximum speed */
    double fast;       /* gain at fast speeds, >= precision */
} AccelerationCurve;

/* The most points libinput accepts; more samples follow the curve closer. */
extern const NSUInteger AccelerationCurvePointCount;

/* Pointer speed the graph spans, in mm/s. */
double AccelerationCurveMaxSpeed(PointerDeviceKind kind);
/* Largest gain the editor offers. */
double AccelerationCurveMaxGain(PointerDeviceKind kind);
/* Close to what the class's System profile does at the default speed. */
AccelerationCurve AccelerationCurveDefaults(PointerDeviceKind kind);

BOOL AccelerationCurveEqualToCurve(AccelerationCurve a, AccelerationCurve b);
/* position is a fraction of the maximum speed. */
double AccelerationCurveGain(AccelerationCurve curve, double position);

/* The libinput "Accel Custom Motion Step" and "Points" for a device with
 * the given resolution: speed in device units per millisecond, points as
 * output speed. */
double AccelerationCurvePointStep(PointerDeviceKind kind, double unitsPerMM);
NSArray *AccelerationCurvePoints(PointerDeviceKind kind, AccelerationCurve curve,
                                 double unitsPerMM);

/* What the System (adaptive) and Flat profiles do at a speed setting of
 * -1..1: a four-parameter approximation for the handles, and gains sampled
 * at count evenly spaced speeds for the drawn line. */
AccelerationCurve AccelerationAdaptiveCurve(PointerDeviceKind kind, double speedSetting);
NSArray *AccelerationAdaptiveGains(PointerDeviceKind kind, double speedSetting, NSUInteger count);
double AccelerationFlatGain(PointerDeviceKind kind, double speedSetting);

/* Mice report no resolution through X or evdev; libinput itself assumes
 * 1000 dpi for a mouse without a MOUSE_DPI hwdb entry, so the pane does
 * too. */
extern const double AccelerationMouseUnitsPerMM;
