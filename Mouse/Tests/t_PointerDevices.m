/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Which X pointers the Mouse pane shows a section for: parsing captured
 * `xinput list` / `xinput list-props` output (Fixtures/) and classifying
 * each device as mouse, touchpad or trackpoint.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PointerDevice.h"

static NSString *const kFixtures = @"Fixtures";

static NSString *Fixture(NSString *name)
{
    NSString *path = [kFixtures stringByAppendingPathComponent:name];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text == nil) {
        fprintf(stderr, "missing fixture %s (run from Mouse/Tests)\n", [path UTF8String]);
        exit(1);
    }
    return text;
}

/* "name=kind" for every slave pointer of a fixture, in list order. */
static NSArray *Classified(NSString *fixture)
{
    NSMutableArray *out = [NSMutableArray array];
    NSArray *pointers = [PointerDevice slavePointersInXinputList:
        Fixture([fixture stringByAppendingPathComponent:@"list"])];
    for (NSDictionary *p in pointers) {
        NSString *propsFile = [fixture stringByAppendingPathComponent:
            [@"props-" stringByAppendingString:[p objectForKey:@"id"]]];
        NSDictionary *props = [PointerDevice propertiesFromXinputListProps:Fixture(propsFile)];
        PointerDeviceKind kind = [PointerDevice kindForName:[p objectForKey:@"name"] properties:props];
        NSString *k = kind == PointerDeviceKindMouse ? @"mouse"
            : kind == PointerDeviceKindTouchpad ? @"touchpad"
            : kind == PointerDeviceKindTrackpoint ? @"trackpoint" : @"none";
        [out addObject:[NSString stringWithFormat:@"%@=%@", [p objectForKey:@"name"], k]];
    }
    return out;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("xinput list parsing")
    {
        NSArray *pointers = [PointerDevice slavePointersInXinputList:Fixture(@"laptop/list")];
        NSArray *ids = [pointers valueForKey:@"id"];
        NSArray *wantIDs = @[@"4", @"12", @"13", @"10", @"15"];
        PASS_EQUAL(ids, wantIDs, "only slave pointers, in list order, master and keyboards left out");
        NSDictionary *touchpad = [pointers objectAtIndex:1];
        PASS_EQUAL([touchpad objectForKey:@"name"], @"SynPS/2 Synaptics TouchPad",
                   "the name loses the tree glyphs and the padding before the id");

        NSString *plain = @"~ Virtual core pointer\tid=2\t[master pointer  (3)]\n"
                          @"~   > Plain Mouse\tid=7\t[slave  pointer  (2)]\n";
        NSArray *wantPlain = @[@{@"id" : @"7", @"name" : @"Plain Mouse"}];
        PASS_EQUAL([PointerDevice slavePointersInXinputList:plain], wantPlain,
                   "a list drawn without the Unicode tree glyphs parses too");
        PASS([[PointerDevice slavePointersInXinputList:@""] count] == 0, "no output: no devices");
    }
    END_SET("xinput list parsing")

    START_SET("xinput list-props parsing")
    {
        NSDictionary *props = [PointerDevice propertiesFromXinputListProps:Fixture(@"laptop/props-12")];
        PASS_EQUAL([props objectForKey:@"libinput Accel Profiles Available"], @"1, 1, 1",
                   "multi-value properties keep their value text");
        PASS_EQUAL([props objectForKey:@"Device Node"], @"\"/dev/input/event6\"",
                   "string properties keep their quotes");
        PointerDevice *d = [[[PointerDevice alloc] initWithID:@"12" name:@"t"
            kind:PointerDeviceKindTouchpad properties:props unitsPerMM:0] autorelease];
        PASS_EQUAL([d libinputValue:@"Tapping Enabled"], @"1",
                   "a property is read by its exact name, not its Default twin");
        PASS_EQUAL([d activeAccelProfile], @"system", "Accel Profile Enabled 1, 0, 0 is System");
        PASS([d offersAccelProfile:@"flat"], "Flat is offered when available");
        PASS(![d offersAccelProfile:@"custom"], "Custom is not offered without the device resolution");
    }
    END_SET("xinput list-props parsing")

    START_SET("classification: laptop with touchpad, trackpoint and USB mouse")
    {
        NSArray *want = @[
            @"Virtual core XTEST pointer=none",
            @"SynPS/2 Synaptics TouchPad=touchpad",
            @"TPPS/2 IBM TrackPoint=trackpoint",
            @"Logitech USB Optical Mouse=mouse",
            @"ThinkPad Extra Buttons=none",
        ];
        PASS_EQUAL(Classified(@"laptop"), want,
                   "tapping makes a touchpad, the name a trackpoint, the rest with acceleration a mouse");
    }
    END_SET("classification: laptop with touchpad, trackpoint and USB mouse")

    START_SET("classification: desktop without a touchpad")
    {
        NSArray *want = @[
            @"Virtual core XTEST pointer=none",
            @"Logitech USB Receiver Mouse=mouse",
            @"Logitech USB Receiver Consumer Control=none",
            @"Kensington Expert Wireless TB Mouse=mouse",
        ];
        PASS_EQUAL(Classified(@"desktop"), want,
                   "two mice, no touchpad or trackpoint; the receiver's consumer control is no pointer");
    }
    END_SET("classification: desktop without a touchpad")

    START_SET("classification rules one by one")
    {
        NSDictionary *pointer = @{@"libinput Accel Speed" : @"0.000000"};
        NSDictionary *tapping = @{@"libinput Accel Speed" : @"0.000000",
                                  @"libinput Tapping Enabled" : @"0"};
        PASS([PointerDevice kindForName:@"Elan Touchpad" properties:@{}] == PointerDeviceKindNone,
             "no libinput acceleration: not configurable, whatever the name says");
        PASS([PointerDevice kindForName:@"ELAN0501:00 04F3:3060" properties:tapping] == PointerDeviceKindTouchpad,
             "a touchpad is recognised by tapping, not by its name");
        PASS([PointerDevice kindForName:@"Elan TrackPoint" properties:pointer] == PointerDeviceKindTrackpoint,
             "TrackPoint in the name");
        PASS([PointerDevice kindForName:@"TPPS/2 Elan TrackPoint" properties:pointer] == PointerDeviceKindTrackpoint,
             "TPPS/2 in the name");
        PASS([PointerDevice kindForName:@"DELL0A71:00 Pointing Stick" properties:pointer] == PointerDeviceKindTrackpoint,
             "Pointing Stick in the name");
        PASS([PointerDevice kindForName:@"Logitech MX Master 3" properties:pointer] == PointerDeviceKindMouse,
             "any other libinput pointer is a mouse");
    }
    END_SET("classification rules one by one")

    [arp release];
    return 0;
}
