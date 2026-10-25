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
 *   display-live primary OUTPUT
 *   display-live mirror | unmirror
 */

#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>
#import "DisplayLayout.h"
#import "X11DisplayManager.h"

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
    } else if ([cmd isEqualToString:@"primary"]) {
        wanted = [layout layoutBySettingPrimary:arg1];
    } else if ([cmd isEqualToString:@"mirror"]) {
        wanted = [layout mirroredLayout];
    } else if ([cmd isEqualToString:@"unmirror"]) {
        wanted = [layout extendedLayout];
    } else {
        return fail([NSString stringWithFormat:@"unknown command %@", cmd]);
    }

    if (wanted == nil) return fail(@"the model refused the request");
    NSError *error = nil;
    if (![x11 applyLayout:wanted error:&error]) {
        return fail([error localizedDescription]);
    }
    DisplayLayout *after = [[[[X11DisplayManager alloc] init] autorelease]
                               currentLayoutProbingOutputs:NO];
    printf("%s\n", [[after description] UTF8String]);
    [pool release];
    return 0;
}
