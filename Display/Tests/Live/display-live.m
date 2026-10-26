/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* display-live - drives the same layout operations the Display pane uses
 * (DisplayLayout + X11DisplayManager) from the command line, so a script
 * can apply them to a private multi-output X server and check the result
 * with xrandr.
 *
 *   display-live dump
 *   display-live enable OUTPUT [WxH]
 *   display-live mode OUTPUT WxH
 *   display-live off OUTPUT
 *   display-live place OUTPUT left-of|right-of|above|below OTHER
 *   display-live move OUTPUT X Y
 *                 drop OUTPUT with its top-left at X,Y (screen pixels of the
 *                 current layout), snapped like a drop in the pane
 *   display-live primary OUTPUT
 *   display-live mirror | unmirror
 *   display-live looks-like OUTPUT [WxH] [-GSScaleFactor F]
 *                 without WxH: list the "looks like" sizes, the current one
 *                 marked with "*"; with WxH: switch to that size
 *   display-live scale OUTPUT S [-GSScaleFactor F]
 *                 draw OUTPUT at S (1, 1.25, ... 3) through the RandR
 *                 "DPI" of every lit output, as the pane's Scale pop-up;
 *                 prints the GSScaleFactor the pane would store
 */

#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>
#import "DisplayLayout.h"
#import "X11DisplayManager.h"
#import "DisplayScaledResolution.h"

static int fail(NSString *text)
{
    fprintf(stderr, "display-live: %s\n", [text UTF8String]);
    return 1;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if ([args count] < 2) return fail(@"usage: see the header of display-live.m");

    /* A test tool that reconfigures monitors must never land on the
     * logged-in user's desktop through an inherited DISPLAY. */
    const char *dpy = getenv("DISPLAY");
    if (dpy == NULL || strcmp(dpy, ":0") == 0 || strcmp(dpy, ":0.0") == 0) {
        return fail(@"set DISPLAY to a private test display (not :0)");
    }

    X11DisplayManager *x11 = [[[X11DisplayManager alloc] init] autorelease];
    DisplayLayout *layout = [x11 currentLayoutProbingOutputs:YES];
    if (layout == nil) return fail(@"cannot read the RandR configuration");

    NSString *cmd = [args objectAtIndex:1];
    NSString *arg1 = [args count] > 2 ? [args objectAtIndex:2] : nil;
    DisplayLayout *wanted = nil;

    if ([cmd isEqualToString:@"dump"]) {
        printf("%s\n", [[layout description] UTF8String]);
        for (DisplayOutput *o in [layout outputs]) {
            printf("%s modes=%s\n", [[o name] UTF8String],
                   [[[o resolutionStrings] componentsJoinedByString:@","] UTF8String]);
        }
        [pool release];
        return 0;
    } else if ([cmd isEqualToString:@"enable"] || [cmd isEqualToString:@"mode"]) {
        DisplayOutput *o = [layout outputNamed:arg1];
        if (o == nil) return fail([NSString stringWithFormat:@"no connected output %@", arg1]);
        NSString *res = [args count] > 3 ? [args objectAtIndex:3]
                                         : [[o preferredMode] sizeString];
        wanted = [layout layoutBySettingResolution:res forOutput:arg1];
    } else if ([cmd isEqualToString:@"off"]) {
        wanted = [layout layoutByDisablingOutput:arg1];
    } else if ([cmd isEqualToString:@"place"] && [args count] > 4) {
        DisplayOutput *o = [layout outputNamed:arg1];
        DisplayOutput *ref = [layout outputNamed:[args objectAtIndex:4]];
        if (o == nil || ref == nil) return fail(@"unknown output");
        NSString *where = [args objectAtIndex:3];
        NSRect r = [ref frame];
        NSSize s = [o size];
        NSPoint p;
        /* A drop slightly off the exact spot, like a hand-made drag. */
        if ([where isEqualToString:@"left-of"]) p = NSMakePoint(NSMinX(r) - s.width - 37, NSMinY(r) + 21);
        else if ([where isEqualToString:@"right-of"]) p = NSMakePoint(NSMaxX(r) + 37, NSMinY(r) + 21);
        else if ([where isEqualToString:@"above"]) p = NSMakePoint(NSMinX(r) + 21, NSMinY(r) - s.height - 37);
        else if ([where isEqualToString:@"below"]) p = NSMakePoint(NSMinX(r) + 21, NSMaxY(r) + 37);
        else return fail(@"place: left-of, right-of, above or below");
        wanted = [layout layoutByMovingOutput:arg1 toOrigin:p snapDistance:64];
    } else if ([cmd isEqualToString:@"move"] && [args count] > 4) {
        if ([layout outputNamed:arg1] == nil) return fail(@"unknown output");
        /* The pane snaps edges within 8 view points; at its usual view
         * scale of about 1/7 that is some 60 screen pixels. */
        NSPoint p = NSMakePoint([[args objectAtIndex:3] doubleValue],
                                [[args objectAtIndex:4] doubleValue]);
        wanted = [layout layoutByMovingOutput:arg1 toOrigin:p snapDistance:56];
    } else if ([cmd isEqualToString:@"primary"]) {
        wanted = [layout layoutBySettingPrimary:arg1];
    } else if ([cmd isEqualToString:@"looks-like"]) {
        DisplayOutput *o = [layout outputNamed:arg1];
        if (o == nil || ![o enabled]) return fail(@"looks-like needs an output that is on");
        /* Tests pass the factor as -GSScaleFactor F (argument domain). */
        double scale = [[NSUserDefaults standardUserDefaults] doubleForKey:@"GSScaleFactor"];
        NSSize mode = [o rotatedModeSize];
        NSSize max = [x11 maximumScreenSize];
        NSArray *options = DisplayScaledResolutions((int)mode.width, (int)mode.height,
                                                    scale > 0 ? scale : 1.0,
                                                    (int)max.width, (int)max.height);
        NSString *size = [args count] > 3 ? [args objectAtIndex:3] : nil;
        if (size == nil || [size hasPrefix:@"-"]) {
            DisplayScaledResolution *cur = DisplayScaledResolutionForTransform(
                options, [o transformScaleX], [o transformScaleY]);
            for (DisplayScaledResolution *r in options) {
                printf("%s %s fb=%dx%d transform=%.6fx%.6f\n", r == cur ? "*" : " ",
                       [[r title] UTF8String], [r framebufferWidth], [r framebufferHeight],
                       [r transformScaleX], [r transformScaleY]);
            }
            [pool release];
            return 0;
        }
        for (DisplayScaledResolution *r in options) {
            NSString *rsize = [NSString stringWithFormat:@"%dx%d",
                               [r logicalWidth], [r logicalHeight]];
            if ([rsize isEqualToString:size]) {
                wanted = [layout layoutBySettingTransformScaleX:[r transformScaleX]
                                                              y:[r transformScaleY]
                                                      forOutput:arg1];
            }
        }
        if (wanted == nil) return fail([NSString stringWithFormat:@"%@ is no looks-like size of %@", size, arg1]);
    } else if ([cmd isEqualToString:@"scale"] && [args count] > 3) {
        double global = [[NSUserDefaults standardUserDefaults] doubleForKey:@"GSScaleFactor"];
        [layout setScaleFactor:global > 0 ? global : 1.0];
        wanted = [layout layoutBySettingScale:[[args objectAtIndex:3] doubleValue]
                                    forOutput:arg1];
        [wanted setScaleFactor:[wanted preferredScaleFactor]];
        if (wanted) printf("GSScaleFactor %g\n", [wanted scaleFactor]);
    } else if ([cmd isEqualToString:@"mirror"]) {
        wanted = [layout mirroredLayout];
    } else if ([cmd isEqualToString:@"unmirror"]) {
        wanted = [layout extendedLayout];
    } else {
        return fail([NSString stringWithFormat:@"unknown command %@", cmd]);
    }

    if (wanted == nil) return fail(@"the model refused the request");
    NSError *error = nil;
    if (![x11 applyLayout:wanted touchedServer:NULL error:&error]) {
        return fail([error localizedDescription]);
    }
    DisplayLayout *after = [[[[X11DisplayManager alloc] init] autorelease]
                               currentLayoutProbingOutputs:NO];
    printf("%s\n", [[after description] UTF8String]);
    [pool release];
    return 0;
}
