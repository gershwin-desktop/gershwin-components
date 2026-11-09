/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The acceleration curve per device class: the libinput custom points a
 * curve becomes on a mouse (1000 dpi, as libinput assumes) and on a
 * touchpad (its own resolution), and what the System and Flat profiles of
 * each class do (libinput 1.28 filter-mouse.c, filter-flat.c,
 * filter-touchpad*.c).  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AccelerationCurve.h"

static BOOL Near(double a, double b)
{
    return fabs(a - b) < 1e-4;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    const PointerDeviceKind mouse = PointerDeviceKindMouse;
    const PointerDeviceKind touchpad = PointerDeviceKindTouchpad;

    START_SET("touchpad curve keeps its libinput points")
    {
        AccelerationCurve c = AccelerationCurveDefaults(touchpad);
        PASS(Near(c.precision, 0.30) && Near(c.start, 0.20) && Near(c.end, 0.70) && Near(c.fast, 1.60),
             "touchpad default curve");
        PASS(Near(AccelerationCurveMaxSpeed(touchpad), 750.0), "touchpad graph spans 750 mm/s");
        PASS(Near(AccelerationCurveMaxGain(touchpad), 2.0), "touchpad gains up to 2");
        /* 12 units/mm: a common touchpad resolution. */
        PASS(Near(AccelerationCurvePointStep(touchpad, 12.0), 0.178571), "step in touchpad units per ms");
        NSArray *points = AccelerationCurvePoints(touchpad, c, 12.0);
        PASS([points count] == 64, "64 points, the most libinput takes");
        PASS(Near([[points objectAtIndex:0] doubleValue], 0.0), "no motion in, none out");
        PASS(Near([[points objectAtIndex:1] doubleValue], 0.178571 * 0.30 * (1000.0 / 25.4) / 12.0),
             "below Start: input speed times Precision, rescaled from touchpad units to 1000 dpi");
    }
    END_SET("touchpad curve keeps its libinput points")

    START_SET("mouse curve is in 1000 dpi units")
    {
        AccelerationCurve c = AccelerationCurveDefaults(mouse);
        PASS(Near(c.precision, 1.0) && Near(c.start, 0.10) && Near(c.end, 0.35) && Near(c.fast, 2.0),
             "mouse default curve follows the System profile: 1:1, up to 2x by 35 mm/s");
        PASS(Near(AccelerationCurveMaxSpeed(mouse), 100.0), "mouse graph spans 100 mm/s");
        PASS(Near(AccelerationCurveMaxGain(mouse), 4.0), "mouse gains up to 4");
        PASS(Near(AccelerationMouseUnitsPerMM, 1000.0 / 25.4), "a mouse counts as 1000 dpi");
        double step = AccelerationCurvePointStep(mouse, AccelerationMouseUnitsPerMM);
        PASS(Near(step, 100.0 * 1.25 / 25.4 / 63.0), "step in mouse units per ms");
        NSArray *points = AccelerationCurvePoints(mouse, c, AccelerationMouseUnitsPerMM);
        PASS([points count] == 64, "64 points");
        PASS(Near([[points objectAtIndex:1] doubleValue], step * 1.0),
             "below Start a mouse moves 1:1, with no touchpad rescaling");
        PASS(Near([[points objectAtIndex:63] doubleValue], 63 * step * 2.0),
             "past End the fast gain holds");
    }
    END_SET("mouse curve is in 1000 dpi units")

    START_SET("mouse System and Flat profiles")
    {
        NSArray *gains = AccelerationAdaptiveGains(mouse, 0.0, 101);
        /* Samples are 1 mm/s apart over the 100 mm/s graph. */
        PASS(Near([[gains objectAtIndex:1] doubleValue], 10.0 * (1.0 / 25.4) + 0.3),
             "1 mm/s: libinput decelerates slow mouse motion");
        PASS(Near([[gains objectAtIndex:5] doubleValue], 1.0), "5 mm/s: 1:1");
        PASS(Near([[gains objectAtIndex:20] doubleValue], 1.1 * (20.0 / 25.4 - 0.4) + 1.0),
             "20 mm/s: on the incline past the 0.4 units/ms threshold");
        PASS(Near([[gains objectAtIndex:50] doubleValue], 2.0), "50 mm/s: capped at 2x");
        gains = AccelerationAdaptiveGains(mouse, 1.0, 101);
        PASS(Near([[gains objectAtIndex:100] doubleValue], 3.5), "fastest speed setting caps at 3.5x");

        AccelerationCurve a = AccelerationAdaptiveCurve(mouse, 0.0);
        PASS(Near(a.precision, 1.0) && Near(a.start, 0.1016) && Near(a.end, 0.332509) && Near(a.fast, 2.0),
             "handles: 1:1 until 10 mm/s, 2x from 33 mm/s");
        PASS(Near(AccelerationFlatGain(mouse, 0.5), 1.5), "mouse Flat is 1 + speed");
        PASS(Near(AccelerationFlatGain(mouse, -1.0), 0.005), "and never stops the pointer");
    }
    END_SET("mouse System and Flat profiles")

    START_SET("touchpad System and Flat profiles")
    {
        PASS(Near(AccelerationFlatGain(touchpad, 0.0), 0.2968), "touchpad Flat carries libinput's touchpad slowdown");
        AccelerationCurve a = AccelerationAdaptiveCurve(touchpad, 0.0);
        PASS(Near(a.precision, 0.9 * 0.2968) && Near(a.start, 130.0 / 750.0) && Near(a.end, 520.0 / 750.0),
             "touchpad adaptive handles");
    }
    END_SET("touchpad System and Flat profiles")

    [arp release];
    return 0;
}
