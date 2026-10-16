/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* libMouseBackend against fake-xinput replaying captured devices: which
 * device each per-class setting reaches and which libinput properties it
 * sets.  fake-xinput rejects a property the device does not have, as xinput
 * does.  Headless; no X server is used. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MouseBackend.h"

static NSString *gWork;

/* A fresh writable copy of a fixture and a wrapper that points fake-xinput
 * at it; the backend copies its own environment into xinput's, so the
 * directory cannot be handed over through setenv(). */
static MouseBackend *BackendFor(NSString *fixture)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cwd = [fm currentDirectoryPath];
    NSString *dir = [gWork stringByAppendingPathComponent:fixture];
    [fm removeItemAtPath:dir error:NULL];
    if (![fm copyItemAtPath:[cwd stringByAppendingPathComponent:
            [@"Fixtures" stringByAppendingPathComponent:fixture]] toPath:dir error:NULL]) {
        fprintf(stderr, "cannot copy fixture %s (run from Mouse/Tests)\n", [fixture UTF8String]);
        exit(1);
    }
    NSString *wrapper = [dir stringByAppendingPathComponent:@"xinput"];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nFAKE_XINPUT_DIR='%@' exec '%@/fake-xinput' \"$@\"\n",
                                 dir, cwd];
    [script writeToFile:wrapper atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm setAttributes:@{NSFilePosixPermissions : @0755} ofItemAtPath:wrapper error:NULL];
    MouseBackend *b = [[[MouseBackend alloc] initWithXinputPath:wrapper] autorelease];
    [b refresh];
    return b;
}

/* The set-prop calls since the last call, one "id|property|values" each. */
static NSArray *TakeLog(NSString *fixture)
{
    NSString *path = [[gWork stringByAppendingPathComponent:fixture]
        stringByAppendingPathComponent:@"set-prop.log"];
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [log componentsSeparatedByString:@"\n"]) {
        if ([l length] > 0) {
            [lines addObject:l];
        }
    }
    return lines;
}

static NSArray *IDs(NSArray *devices)
{
    return [devices valueForKey:@"deviceID"];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    gWork = [[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"t_MouseBackend-%d", getpid()]] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:gWork
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    START_SET("devices found on a laptop")
    {
        MouseBackend *b = BackendFor(@"laptop");
        NSArray *want = @[@"12"];
        PASS_EQUAL(IDs([b devicesOfKind:PointerDeviceKindTouchpad]), want, "one touchpad");
        want = @[@"13"];
        PASS_EQUAL(IDs([b devicesOfKind:PointerDeviceKindTrackpoint]), want, "one trackpoint");
        want = @[@"10"];
        PASS_EQUAL(IDs([b devicesOfKind:PointerDeviceKindMouse]), want, "one mouse");
        PASS([[b devices] count] == 3, "XTEST and the extra buttons are left out");
        PointerDevice *mouse = [[b devicesOfKind:PointerDeviceKindMouse] firstObject];
        PASS(fabs([mouse unitsPerMM] - AccelerationMouseUnitsPerMM) < 1e-9, "a mouse counts as 1000 dpi");
        PASS([mouse offersAccelProfile:@"custom"], "so a mouse is offered the Custom profile");
    }
    END_SET("devices found on a laptop")

    START_SET("per-class settings reach only that class")
    {
        MouseBackend *b = BackendFor(@"laptop");
        PASS([b applySpeed:0.5 toKind:PointerDeviceKindMouse], "mouse speed applied");
        NSArray *want = @[@"10|libinput Accel Speed|0.500"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "only the mouse gets the mouse speed");

        PASS([b applyNaturalScrolling:YES toKind:PointerDeviceKindTouchpad], "trackpad scrolling applied");
        want = @[@"12|libinput Natural Scrolling Enabled|1"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "only the touchpad scrolls naturally");

        PASS([b applyLeftHanded:YES toKind:PointerDeviceKindMouse], "mouse handedness applied");
        want = @[@"10|libinput Left Handed Enabled|1"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "only the mouse swaps its buttons");

        PASS([b applyScrollSpeed:1.5 toKind:PointerDeviceKindTouchpad], "trackpad scroll speed applied");
        want = @[@"12|libinput Scrolling Pixel Distance|10"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "1.5x is libinput's shortest 10 px distance");
        PASS([b applyScrollSpeed:1.0 toKind:PointerDeviceKindMouse], "a mouse wheel has no scroll distance");
        PASS([TakeLog(@"laptop") count] == 0, "so nothing is set on the mouse");
    }
    END_SET("per-class settings reach only that class")

    START_SET("acceleration profiles for mice and touchpads")
    {
        MouseBackend *b = BackendFor(@"laptop");
        AccelerationCurve c = AccelerationCurveDefaults(PointerDeviceKindMouse);
        PASS([b applyAccelProfile:@"custom" curve:c toKind:PointerDeviceKindMouse], "mouse custom curve applied");
        NSArray *log = TakeLog(@"laptop");
        PASS([log count] == 3, "points, step, profile");
        NSArray *first = [[log objectAtIndex:0] componentsSeparatedByString:@"|"];
        PASS_EQUAL([first objectAtIndex:1], @"libinput Accel Custom Motion Points", "points first");
        PASS([[[first objectAtIndex:2] componentsSeparatedByString:@", "] count] == 64, "64 points");
        NSString *step = [NSString stringWithFormat:@"10|libinput Accel Custom Motion Step|%.6f",
            AccelerationCurvePointStep(PointerDeviceKindMouse, AccelerationMouseUnitsPerMM)];
        PASS_EQUAL([log objectAtIndex:1], step, "the step is in mouse units per ms");
        PASS_EQUAL([log objectAtIndex:2], @"10|libinput Accel Profile Enabled|0, 0, 1",
                   "the custom profile is enabled last, on the new points");

        PASS([b applyAccelProfile:@"flat" curve:c toKind:PointerDeviceKindTouchpad], "trackpad flat applied");
        NSArray *want = @[@"12|libinput Accel Profile Enabled|0, 1, 0"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "only the flag changes for a built-in profile");

        PASS(![b applyAccelProfile:@"custom" curve:c toKind:PointerDeviceKindTouchpad],
             "a touchpad whose resolution cannot be read refuses a custom curve");
        PASS([TakeLog(@"laptop") count] == 0, "and nothing half-applied is left behind");
        PASS(![b applyAccelProfile:@"bogus" curve:c toKind:PointerDeviceKindMouse], "unknown profile refused");
    }
    END_SET("acceleration profiles for mice and touchpads")

    START_SET("touchpad tapping uses the driver's property names")
    {
        MouseBackend *b = BackendFor(@"laptop");
        PASS([b applyTwoFingerRightClick:YES threeFingerMiddleClick:YES], "tap mapping applied");
        NSArray *want = @[@"12|libinput Tapping Button Mapping Enabled|1, 0",
                          @"12|libinput Clickfinger Button Mapping Enabled|1, 0"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "two-finger right, three-finger middle is left-right-middle");
        PASS([b applyTwoFingerRightClick:NO threeFingerMiddleClick:NO], "other mapping applied");
        want = @[@"12|libinput Tapping Button Mapping Enabled|0, 1",
                 @"12|libinput Clickfinger Button Mapping Enabled|0, 1"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "otherwise left-middle-right, the only other mapping libinput has");
        PASS([b applyTapToClick:YES], "tap to click applied");
        want = @[@"12|libinput Tapping Enabled|1"];
        PASS_EQUAL(TakeLog(@"laptop"), want, "tapping on the touchpad");
    }
    END_SET("touchpad tapping uses the driver's property names")

    START_SET("a desktop without a touchpad")
    {
        MouseBackend *b = BackendFor(@"desktop");
        PASS([[b devicesOfKind:PointerDeviceKindTouchpad] count] == 0, "no touchpad");
        NSArray *want = @[@"9", @"16"];
        PASS_EQUAL(IDs([b devicesOfKind:PointerDeviceKindMouse]), want, "two mice");
        PASS([b applyTapToClick:YES] && [b applyDisableWhileTyping:YES],
             "touchpad settings without a touchpad are not failures");
        PASS([b applySpeed:-0.25 toKind:PointerDeviceKindMouse], "mouse speed applied");
        want = @[@"9|libinput Accel Speed|-0.250", @"16|libinput Accel Speed|-0.250"];
        PASS_EQUAL(TakeLog(@"desktop"), want, "every mouse gets the class's setting");
    }
    END_SET("a desktop without a touchpad")

    START_SET("no xinput")
    {
        MouseBackend *b = [[[MouseBackend alloc] initWithXinputPath:nil] autorelease];
        [b refresh];
        PASS([[b devices] count] == 0, "no devices");
        PASS(![b applySpeed:0 toKind:PointerDeviceKindMouse], "applying fails loudly");
    }
    END_SET("no xinput")

    [[NSFileManager defaultManager] removeItemAtPath:gWork error:NULL];
    [arp release];
    return 0;
}
