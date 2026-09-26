/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The MousePreferences keys per device class and the move of the older
 * shared keys to them.  Headless; the user's defaults are not touched. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MousePreferences.h"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("keys per device class")
    {
        PASS_EQUAL([MousePreferences key:MousePreferencesSpeed forKind:PointerDeviceKindMouse],
                   @"mouseSpeed", "mouse speed keeps its key");
        PASS_EQUAL([MousePreferences key:MousePreferencesSpeed forKind:PointerDeviceKindTouchpad],
                   @"trackpadSpeed", "trackpad speed keeps its key");
        PASS_EQUAL([MousePreferences key:MousePreferencesSpeed forKind:PointerDeviceKindTrackpoint],
                   @"trackpointSpeed", "trackpoint speed keeps its key");
        PASS_EQUAL([MousePreferences key:MousePreferencesNaturalScrolling forKind:PointerDeviceKindMouse],
                   @"mouseNaturalScrolling", "scroll direction per class");
        PASS_EQUAL([MousePreferences key:MousePreferencesLeftHanded forKind:PointerDeviceKindTouchpad],
                   @"trackpadLeftHanded", "primary button per class");
        NSArray *want = @[@"mouseCurveProfile", @"mouseCurvePrecision", @"mouseCurveStart",
                          @"mouseCurveEnd", @"mouseCurveFast"];
        PASS_EQUAL([MousePreferences curveKeysForKind:PointerDeviceKindMouse], want, "mouse curve keys");
        want = @[@"trackpadCurveProfile", @"trackpadCurvePrecision", @"trackpadCurveStart",
                 @"trackpadCurveEnd", @"trackpadCurveFast"];
        PASS_EQUAL([MousePreferences curveKeysForKind:PointerDeviceKindTouchpad], want, "trackpad curve keys");
    }
    END_SET("keys per device class")

    START_SET("reading a stored curve")
    {
        AccelerationCurve c;
        NSDictionary *d = @{@"mouseCurvePrecision" : @0.8, @"mouseCurveStart" : @0.1,
                            @"mouseCurveEnd" : @"0.4", @"mouseCurveFast" : @2.5};
        PASS([MousePreferences curve:&c forKind:PointerDeviceKindMouse inDomain:d]
             && c.precision == 0.8 && c.start == 0.1 && c.end == 0.4 && c.fast == 2.5,
             "four parameters read, a number written as a string included");
        PASS(![MousePreferences curve:&c forKind:PointerDeviceKindTouchpad inDomain:d],
             "another class's curve is not taken");
        d = @{@"mouseCurvePrecision" : @0.8, @"mouseCurveStart" : @0.1, @"mouseCurveEnd" : @0.4};
        PASS(![MousePreferences curve:&c forKind:PointerDeviceKindMouse inDomain:d],
             "an incomplete curve is not read");
    }
    END_SET("reading a stored curve")

    START_SET("older shared keys move to the device classes")
    {
        NSDictionary *old = @{
            @"naturalScrolling" : @YES, @"leftHanded" : @NO, @"mouseSpeed" : @0.25,
            @"curveProfile" : @"custom", @"curvePrecision" : @0.3, @"curveStart" : @0.2,
            @"curveEnd" : @0.7, @"curveFast" : @1.6, @"tapToClick" : @YES,
        };
        NSDictionary *want = @{
            @"mouseNaturalScrolling" : @YES, @"trackpadNaturalScrolling" : @YES,
            @"trackpointNaturalScrolling" : @YES,
            @"mouseLeftHanded" : @NO, @"trackpadLeftHanded" : @NO, @"trackpointLeftHanded" : @NO,
            @"mouseSpeed" : @0.25,
            @"trackpadCurveProfile" : @"custom", @"trackpadCurvePrecision" : @0.3,
            @"trackpadCurveStart" : @0.2, @"trackpadCurveEnd" : @0.7, @"trackpadCurveFast" : @1.6,
            @"tapToClick" : @YES,
        };
        PASS_EQUAL([MousePreferences migratedDomain:old], want,
                   "shared scrolling and handedness go to every class, the curve was the trackpad's");

        NSDictionary *mixed = @{@"naturalScrolling" : @YES, @"mouseNaturalScrolling" : @NO};
        NSDictionary *m = [MousePreferences migratedDomain:mixed];
        PASS_EQUAL([m objectForKey:@"mouseNaturalScrolling"], @NO, "a per-class key already set wins");
        PASS_EQUAL([m objectForKey:@"trackpadNaturalScrolling"], @YES, "the others take the shared value");
        PASS([m objectForKey:@"naturalScrolling"] == nil, "the shared key is gone");

        NSDictionary *current = @{@"mouseSpeed" : @0.1};
        PASS_EQUAL([MousePreferences migratedDomain:current], current, "nothing to move: unchanged");
    }
    END_SET("older shared keys move to the device classes")

    [arp release];
    return 0;
}
