/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* t_DisplayScaledResolution - per-monitor "looks like" sizes through RandR
 * transforms: which sizes are offered, their framebuffer sizes (even, and
 * exactly what the server makes of the 16.16 transform), the transform
 * read back from the server, the neighbors moving around a scaled monitor,
 * and the transform surviving the stored form and the apply decision.
 * Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayLayout.h"
#import "DisplayArrangement.h"
#import "DisplayConfiguration.h"
#import "DisplayScaledResolution.h"

static DisplayMode *M(unsigned long ident, int w, int h, BOOL pref)
{
    return [DisplayMode modeWithID:ident width:w height:h refresh:60
                        interlaced:NO preferred:pref];
}

static DisplayOutput *O(NSString *name, int w, int h, int x, int y, BOOL primary)
{
    DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
    [o setName:name];
    [o setConnected:YES];
    [o setEnabled:YES];
    [o setModes:[NSArray arrayWithObject:M(1, w, h, YES)]];
    [o setModeWidth:w];
    [o setModeHeight:h];
    [o setModeRefresh:60];
    [o setX:x];
    [o setY:y];
    [o setPrimary:primary];
    return o;
}

static NSString *sizes(NSArray *options)
{
    NSMutableArray *parts = [NSMutableArray array];
    for (DisplayScaledResolution *r in options) [parts addObject:[r title]];
    return [parts componentsJoinedByString:@", "];
}

static NSString *rect(NSRect r)
{
    return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f",
            NSMinX(r), NSMinY(r), NSWidth(r), NSHeight(r)];
}

static BOOL allEvenAndExact(NSArray *options, int w, int h)
{
    for (DisplayScaledResolution *r in options) {
        if ([r framebufferWidth] % 2 || [r framebufferHeight] % 2) {
            if (![r isDefault]) return NO;
        }
        if (DisplayTransformedExtent(w, [r transformScaleX]) != [r framebufferWidth]
            || DisplayTransformedExtent(h, [r transformScaleY]) != [r framebufferHeight]) {
            return NO;
        }
    }
    return YES;
}

static double readBack(double scale)
{
    return DisplayFixedFromDouble(scale) / 65536.0;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("4K panel at GSScaleFactor 2")
        NSArray *o = DisplayScaledResolutions(3840, 2160, 2.0, 8192, 8192);
        PASS_EQUAL(sizes(o), @"1280x720, 1536x864, 1920x1080 (Default), 2194x1234, "
                             @"2560x1440, 3072x1728, 3840x2160",
                   "every offered step, from the largest text to the most space");
        DisplayScaledResolution *def = [o count] == 7 ? [o objectAtIndex:2] : nil;
        PASS(def && [def isDefault] && [def transformScaleX] == 1.0
             && [def transformScaleY] == 1.0 && [def framebufferWidth] == 3840
             && [def effectiveScale] == 2.0,
             "the default runs the mode without a transform");
        DisplayScaledResolution *qhd = [o count] == 7 ? [o objectAtIndex:4] : nil;
        PASS(qhd && [qhd framebufferWidth] == 5120 && [qhd framebufferHeight] == 2880
             && fabs([qhd transformScaleX] - 4.0 / 3.0) < 1e-12
             && [qhd effectiveScale] == 1.5 && ![qhd isDefault],
             "looks like 2560x1440: a 5120x2880 framebuffer, transform 4/3");
        DisplayScaledResolution *odd = [o count] == 7 ? [o objectAtIndex:3] : nil;
        PASS(odd && [odd framebufferWidth] == 4388 && [odd framebufferHeight] == 2468
             && [odd transformScaleX] == 4388.0 / 3840 && [odd transformScaleY] == 2468.0 / 2160,
             "a step that does not divide evenly rounds the framebuffer to even sizes, "
             "each axis with its own exact transform");
        PASS(allEvenAndExact(o, 3840, 2160),
             "the server's 16.16 bounds of every option are exactly its framebuffer");

        o = DisplayScaledResolutions(3840, 2160, 2.0, 4096, 4096);
        PASS_EQUAL(sizes(o), @"1280x720, 1536x864, 1920x1080 (Default)",
                   "sizes whose framebuffer exceeds the server's maximum screen are left out");
        o = DisplayScaledResolutions(3840, 2160, 2.0, 0, 0);
        PASS([o count] == 7, "an unknown maximum screen size limits nothing");
    END_SET("4K panel at GSScaleFactor 2")

    START_SET("other monitors")
        NSArray *o = DisplayScaledResolutions(1920, 1080, 2.0, 8192, 8192);
        PASS_EQUAL(sizes(o), @"960x540 (Default), 1280x720, 1536x864, 1920x1080",
                   "a normal monitor next to a HiDPI panel can look like itself again, "
                   "and nothing below 720 points high is offered besides the default");
        PASS(allEvenAndExact(o, 1920, 1080), "even and exact at 1080p");

        o = DisplayScaledResolutions(1920, 1080, 1.0, 8192, 8192);
        PASS_EQUAL(sizes(o), @"1280x720, 1536x864, 1920x1080 (Default)",
                   "at factor 1 only larger text is offered, never more points than pixels");

        o = DisplayScaledResolutions(1366, 768, 1.0, 8192, 8192);
        PASS_EQUAL(sizes(o), @"1366x768 (Default)",
                   "a small laptop panel has only its default");

        o = DisplayScaledResolutions(2560, 1440, 1.25, 8192, 8192);
        PASS_EQUAL(sizes(o), @"1280x720, 1462x822, 1707x960, 2048x1152 (Default), 2560x1440",
                   "a fractional global factor: points are the framebuffer divided by it");
        PASS(allEvenAndExact(o, 2560, 1440), "even and exact at a fractional factor");

        o = DisplayScaledResolutions(2160, 3840, 2.0, 8192, 8192);
        PASS([o count] == 7 && [[o objectAtIndex:4] framebufferWidth] == 2880
             && [[o objectAtIndex:4] framebufferHeight] == 5120,
             "a portrait monitor gets the same choices, turned");
    END_SET("other monitors")

    START_SET("transform read back from the server")
        NSArray *o = DisplayScaledResolutions(3840, 2160, 2.0, 8192, 8192);
        DisplayScaledResolution *r = DisplayScaledResolutionForTransform(o,
            readBack(4.0 / 3.0), readBack(4.0 / 3.0));
        PASS(r && [r logicalWidth] == 2560, "4/3 after the fixed point round trip is 2560x1440");
        r = DisplayScaledResolutionForTransform(o, readBack(4388.0 / 3840), readBack(2468.0 / 2160));
        PASS(r && [r logicalWidth] == 2194, "each axis is matched on its own");
        r = DisplayScaledResolutionForTransform(o, 1.0, 1.0);
        PASS(r && [r isDefault], "no transform is the default");
        PASS(DisplayScaledResolutionForTransform(o, 1.2, 1.2) == nil,
             "a transform of no offered size (a mirror) selects nothing");
    END_SET("transform read back from the server")

    START_SET("neighbors around a scaled monitor")
        DisplayLayout *l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 3840, 2160, 0, 0, YES), O(@"HDMI-1", 1920, 1080, 3840, 0, NO), nil]];
        DisplayLayout *s = [l layoutBySettingTransformScaleX:4.0 / 3.0 y:4.0 / 3.0
                                                   forOutput:@"eDP-1"];
        PASS_EQUAL(rect([[s outputNamed:@"eDP-1"] frame]), @"0,0 5120x2880",
                   "the scaled panel covers its framebuffer size");
        PASS_EQUAL(rect([[s outputNamed:@"HDMI-1"] frame]), @"5120,0 1920x1080",
                   "the monitor to its right moves out of the way");
        PASS_EQUAL(rect([s boundingRect]), @"0,0 7040x2880",
                   "the screen covers the transformed sizes");
        PASS([[l outputNamed:@"eDP-1"] transformScaleX] == 1.0, "the receiver is left alone");

        DisplayLayout *back = [s layoutBySettingTransformScaleX:1.0 y:1.0 forOutput:@"eDP-1"];
        PASS_EQUAL(rect([[back outputNamed:@"HDMI-1"] frame]), @"3840,0 1920x1080",
                   "back to the default, the neighbor closes the gap again");
        PASS(![[back outputNamed:@"eDP-1"] hasTransform], "and the panel has no transform");

        s = [l layoutBySettingTransformScaleX:2.0 y:2.0 forOutput:@"HDMI-1"];
        PASS_EQUAL(rect([[s outputNamed:@"HDMI-1"] frame]), @"3840,0 3840x2160",
                   "scaling the right monitor keeps it where it is");
        PASS_EQUAL(rect([[s outputNamed:@"eDP-1"] frame]), @"0,0 3840x2160",
                   "and the primary at 0,0");

        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 3840, 2160, 1920, 0, YES), O(@"HDMI-1", 1920, 1080, 0, 0, NO), nil]];
        s = [l layoutBySettingTransformScaleX:2.0 y:2.0 forOutput:@"HDMI-1"];
        PASS_EQUAL(rect([[s outputNamed:@"HDMI-1"] frame]), @"0,0 3840x2160",
                   "a monitor on the left grows at its own origin");
        PASS_EQUAL(rect([[s outputNamed:@"eDP-1"] frame]), @"3840,0 3840x2160",
                   "and the panel to its right follows");

        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 3840, 2160, 0, 0, YES), O(@"DP-1", 2560, 1440, 0, 2160, NO), nil]];
        s = [l layoutBySettingTransformScaleX:4.0 / 3.0 y:4.0 / 3.0 forOutput:@"eDP-1"];
        PASS_EQUAL(rect([[s outputNamed:@"DP-1"] frame]), @"0,2880 2560x1440",
                   "a monitor below moves down");

        PASS([l layoutBySettingTransformScaleX:2.0 y:2.0 forOutput:@"nope"] == nil,
             "an unknown output is refused");
        DisplayLayout *mirror = [[DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 1920, 1080, 0, 0, YES), O(@"HDMI-1", 1920, 1080, 0, 0, NO), nil]]
            mirroredLayout];
        PASS(mirror && [mirror isMirrored]
             && [mirror layoutBySettingTransformScaleX:2.0 y:2.0 forOutput:@"HDMI-1"] == nil,
             "a mirror is refused: its transforms belong to the mirror");
        DisplayLayout *off = [l layoutByDisablingOutput:@"DP-1"];
        PASS([off layoutBySettingTransformScaleX:2.0 y:2.0 forOutput:@"DP-1"] == nil,
             "an output that is off is refused");

        DisplayOutput *turned = O(@"DP-2", 3840, 2160, 0, 0, YES);
        [turned setRotation:2];
        PASS(NSEqualSizes([turned rotatedModeSize], NSMakeSize(2160, 3840)),
             "a quarter turn swaps the mode size the options are computed from");
        PASS(NSEqualSizes([O(@"DP-3", 3840, 2160, 0, 0, YES) rotatedModeSize],
                          NSMakeSize(3840, 2160)), "unturned it is the mode size");
        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 3840, 2160, 0, 0, YES), O(@"HDMI-1", 1920, 1080, 3840, 0, NO), nil]];
        s = [l layoutBySettingTransformScaleX:0.8 y:0.8 forOutput:@"eDP-1"];
        PASS_EQUAL(rect([[s outputNamed:@"eDP-1"] frame]), @"0,0 3072x1728",
                   "looks like 1536x864: the panel covers 3072x1728 screen pixels");
        PASS_EQUAL(rect([[s outputNamed:@"HDMI-1"] frame]), @"3072,0 1920x1080",
                   "and its neighbor moves in");
        PASS_EQUAL(rect([[s outputNamed:@"eDP-1"] screenExtent]), @"0,0 3840x2160",
                   "but the screen must still hold the untransformed mode, which is what "
                   "RRSetScreenSize checks");
        PASS_EQUAL(rect([[s outputNamed:@"HDMI-1"] screenExtent]), @"3072,0 1920x1080",
                   "an output without a transform needs just its frame");
        PASS_EQUAL(rect([[[l layoutBySettingTransformScaleX:4.0 / 3.0 y:4.0 / 3.0
                                                  forOutput:@"eDP-1"] outputNamed:@"eDP-1"]
                            screenExtent]), @"0,0 5120x2880",
                   "a transform above 1 needs its frame");
    END_SET("neighbors around a scaled monitor")

    START_SET("saved and applied")
        DisplayLayout *l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(@"eDP-1", 3840, 2160, 0, 0, YES), O(@"HDMI-1", 1920, 1080, 3840, 0, NO), nil]];
        DisplayLayout *s = [l layoutBySettingTransformScaleX:4.0 / 3.0 y:4.0 / 3.0
                                                   forOutput:@"eDP-1"];
        DisplayLayout *stored = [DisplayLayout layoutWithPropertyList:[s propertyList]];
        PASS(fabs([[stored outputNamed:@"eDP-1"] transformScaleX] - 4.0 / 3.0) < 1e-12
             && [[stored outputNamed:@"HDMI-1"] x] == 5120,
             "the stored form keeps the transform and the moved neighbor");
        PASS(s && DisplayLayoutsDiffer(s, l), "a changed transform is a change to apply");
        NSString *problem = nil;
        DisplayLayout *resolved = DisplayResolveSavedLayout(stored, l, &problem);
        PASS(resolved && fabs([[resolved outputNamed:@"eDP-1"] transformScaleX] - 4.0 / 3.0) < 1e-12
             && DisplayLayoutsDiffer(resolved, l) && !DisplayLayoutsDiffer(resolved, s),
             "displayconfig apply brings the saved transform back");
    END_SET("saved and applied")

    [arp release];
    return 0;
}
