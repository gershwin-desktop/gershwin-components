/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_DisplayOutputScale - per-monitor scale: the RandR "DPI" value math,
 * when a DPI is written, the "all equal" rule that decides between the
 * per-monitor factors and GSScaleFactor, setting a monitor's scale, what
 * the pane shows, and the stored form.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayLayout.h"
#import "DisplayConfiguration.h"

static DisplayOutput *O(NSString *name, int x, BOOL primary, double scale)
{
    DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
    [o setName:name];
    [o setEdidIdentity:[NSString stringWithFormat:@"TST-0001-%@", name]];
    [o setConnected:YES];
    [o setEnabled:YES];
    [o setModes:[NSArray arrayWithObject:
        [DisplayMode modeWithID:1 width:1920 height:1080 refresh:60
                     interlaced:NO preferred:YES]]];
    [o setModeWidth:1920];
    [o setModeHeight:1080];
    [o setModeRefresh:60];
    [o setX:x];
    [o setPrimary:primary];
    [o setScale:scale];
    return o;
}

static DisplayLayout *two(double scaleA, double scaleB, double global)
{
    DisplayLayout *l = [DisplayLayout layoutWithOutputs:
        [NSArray arrayWithObjects:O(@"A", 0, YES, scaleA),
                                  O(@"B", 1920, NO, scaleB), nil]];
    [l setScaleFactor:global];
    return l;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("DPI value math")
    {
        PASS(DisplayDPIForScale(1.0) == 96, "1.0 is 96 dpi");
        PASS(DisplayDPIForScale(1.25) == 120, "1.25 is 120 dpi");
        PASS(DisplayDPIForScale(1.75) == 168, "1.75 is 168 dpi");
        PASS(DisplayDPIForScale(2.0) == 192, "2.0 is 192 dpi");
        PASS(DisplayDPIForScale(3.0) == 288, "3.0 is 288 dpi");
        PASS(DisplayDPIForScale(1.3) == 120, "an odd factor is snapped to a step first");
        PASS(DisplayScaleForDPI(192) == 2.0, "192 dpi reads back as 2.0");
        PASS(DisplayScaleForDPI(144) == 1.5, "144 dpi reads back as 1.5");
        PASS(DisplayScaleForDPI(100) == 1.0, "100 dpi reads back as the nearest step");
        PASS(DisplayScaleForDPI(0) == 0.0 && DisplayScaleForDPI(-1) == 0.0,
             "no or a nonsense DPI: no own scale");
    }
    END_SET("DPI value math")

    START_SET("when a DPI is written")
    {
        PASS(!DisplayShouldWriteDPI(192, 192, YES), "same value: no write, no event");
        PASS(DisplayShouldWriteDPI(96, 192, YES), "different value: write");
        PASS(DisplayShouldWriteDPI(-1, 192, YES), "missing, layout has own scales: create");
        PASS(!DisplayShouldWriteDPI(-1, 96, NO),
             "missing, layout without own scales: a server without DPI stays so");
        PASS(DisplayShouldWriteDPI(192, 96, NO),
             "existing stale value, layout without own scales: made uniform");
    }
    END_SET("when a DPI is written")

    START_SET("the all equal rule")
    {
        DisplayLayout *l = two(0, 0, 1.5);
        PASS(![l hasOutputScales], "no own scale anywhere");
        PASS(![l hasMixedScales], "both follow the global factor: not mixed");
        PASS([l preferredScaleFactor] == 1.5, "GSScaleFactor stays the global one");
        PASS([l effectiveScaleForOutputNamed:@"B"] == 1.5, "B shows the global factor");

        l = two(2.0, 2.0, 1.0);
        PASS(![l hasMixedScales], "equal own scales: not mixed");
        PASS([l preferredScaleFactor] == 2.0, "GSScaleFactor becomes the common scale");
        PASS([l effectiveScaleForOutputNamed:@"A"] == 1.0,
             "until it is written, the toolkit uses GSScaleFactor, so the pane shows that");

        l = two(2.0, 1.0, 1.0);
        PASS([l hasMixedScales], "different own scales: mixed");
        PASS([l preferredScaleFactor] == 2.0, "mixed: GSScaleFactor is the primary's scale");
        PASS([l effectiveScaleForOutputNamed:@"A"] == 2.0
             && [l effectiveScaleForOutputNamed:@"B"] == 1.0,
             "mixed: each output shows its own scale");

        l = two(1.0, 0, 1.0);
        PASS(![l hasMixedScales], "an output without own scale follows the global factor");
        l = two(2.0, 0, 1.0);
        PASS([l hasMixedScales], "own 2.0 next to a global 1.0 is mixed");

        [[[l outputs] objectAtIndex:1] setEnabled:NO];
        PASS(![l hasMixedScales], "an output that is off does not count");

        NSDictionary *dpi = [two(2.0, 1.0, 1.0) DPIByOutputName];
        PASS([[dpi objectForKey:@"A"] longValue] == 192
             && [[dpi objectForKey:@"B"] longValue] == 96, "DPI of every lit output");
        dpi = [two(0, 0, 1.5) DPIByOutputName];
        PASS([[dpi objectForKey:@"A"] longValue] == 144
             && [[dpi objectForKey:@"B"] longValue] == 144,
             "without own scales every output gets the global factor: uniform");
    }
    END_SET("the all equal rule")

    START_SET("DPI read from the server")
    {
        DisplayLayout *l = two(2.0, 0, 1.0);
        [l completeServerScales];
        PASS([[l outputNamed:@"B"] scale] == 1.0,
             "an output without DPI next to one with it is 1.0, as for the toolkit");
        l = two(0, 0, 1.25);
        [l completeServerScales];
        PASS([[l outputNamed:@"A"] scale] == 0 && [[l outputNamed:@"B"] scale] == 0,
             "no DPI anywhere: every output follows the global factor");
    }
    END_SET("DPI read from the server")

    START_SET("setting a monitor's scale")
    {
        DisplayLayout *l = two(0, 0, 1.0);
        DisplayLayout *w = [l layoutBySettingScale:2.0 forOutput:@"B"];
        PASS(w != nil && w != l, "a new layout");
        PASS([[l outputNamed:@"B"] scale] == 0, "the receiver is left alone");
        PASS([[w outputNamed:@"B"] scale] == 2.0, "B gets its scale");
        PASS([[w outputNamed:@"A"] scale] == 1.0,
             "A keeps what it showed, now as its own scale");
        PASS([w hasMixedScales] && [w preferredScaleFactor] == 1.0,
             "mixed; GSScaleFactor follows the primary A");

        DisplayLayout *u = [w layoutBySettingScale:1.0 forOutput:@"B"];
        PASS(![u hasMixedScales] && [u preferredScaleFactor] == 1.0, "back to all equal");

        /* A stale uniform DPI that the toolkit ignores must not leak into
         * the other output. */
        l = two(2.0, 2.0, 1.0);
        w = [l layoutBySettingScale:1.5 forOutput:@"A"];
        PASS([[w outputNamed:@"B"] scale] == 1.0,
             "B keeps the 1.0 it showed, not its ignored DPI");

        PASS([[[two(0, 0, 1.0) layoutBySettingScale:1.3 forOutput:@"A"]
                outputNamed:@"A"] scale] == 1.25, "snapped to an offered step");
        PASS([two(0, 0, 1.0) layoutBySettingScale:2.0 forOutput:@"X"] == nil,
             "unknown output: nil");
        l = two(0, 0, 1.0);
        [[l outputNamed:@"B"] setEnabled:NO];
        PASS([l layoutBySettingScale:2.0 forOutput:@"B"] == nil, "output that is off: nil");

        /* One concept of scale: a "looks like" transform on top of the DPI
         * would scale the monitor twice. */
        l = two(0, 0, 1.0);
        [[l outputNamed:@"B"] setTransformScaleX:1.5];
        [[l outputNamed:@"B"] setTransformScaleY:1.5];
        w = [l layoutBySettingScale:2.0 forOutput:@"B"];
        PASS(w && ![[w outputNamed:@"B"] hasTransform], "the transform is reset to identity");

        DisplayLayout *m = [two(0, 0, 1.0) mirroredLayout];
        w = [m layoutBySettingScale:2.0 forOutput:@"B"];
        PASS([[w outputNamed:@"A"] scale] == 2.0 && [[w outputNamed:@"B"] scale] == 2.0
             && [w isMirrored], "a mirror shows one picture: both get the scale");
    }
    END_SET("setting a monitor's scale")

    START_SET("stored form")
    {
        DisplayLayout *l = two(2.0, 1.0, 1.0);
        DisplayLayout *back = [DisplayLayout layoutWithPropertyList:[l propertyList]];
        PASS([[back outputNamed:@"A"] scale] == 2.0 && [[back outputNamed:@"B"] scale] == 1.0,
             "per-output scales survive the round trip");
        PASS([back isEqual:l], "equal after the round trip");

        NSDictionary *plain = [[[two(0, 0, 1.0) propertyList] objectForKey:@"outputs"]
                               objectAtIndex:0];
        PASS([plain objectForKey:@"scale"] == nil, "no own scale: no key, as before");

        NSMutableDictionary *old = [[[l propertyList] mutableCopy] autorelease];
        NSMutableArray *outs = [NSMutableArray array];
        for (NSDictionary *d in [old objectForKey:@"outputs"]) {
            NSMutableDictionary *m = [[d mutableCopy] autorelease];
            [m removeObjectForKey:@"scale"];
            [outs addObject:m];
        }
        [old setObject:outs forKey:@"outputs"];
        [old setObject:[NSNumber numberWithDouble:1.5] forKey:@"scaleFactor"];
        back = [DisplayLayout layoutWithPropertyList:old];
        PASS([[back outputNamed:@"A"] scale] == 0 && ![back hasMixedScales]
             && [back effectiveScaleForOutputNamed:@"A"] == 1.5,
             "a layout stored before: every output follows the global factor");

        NSString *problem = nil;
        DisplayLayout *current = two(0, 0, 1.0);
        DisplayLayout *resolved = DisplayResolveSavedLayout(l, current, &problem);
        PASS(resolved && [[resolved outputNamed:@"A"] scale] == 2.0
             && [[resolved outputNamed:@"B"] scale] == 1.0,
             "resolving a saved layout carries the scales to the connected outputs");
    }
    END_SET("stored form")

    [arp release];
    return 0;
}
