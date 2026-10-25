/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWDisplayScale.h"
#import "GSDisplayScaleHeuristic.h"
#include <X11/extensions/Xrandr.h>

NSString * const LWSystemDisplayDefaultsFileName = @"Display.plist";

// The primary output, or the first connected one when no primary is set
// (a bare X server has none until a client sets it).
static RROutput primaryOrFirstConnectedOutput(Display *display,
                                              XRRScreenResources *res)
{
    RROutput primary = XRRGetOutputPrimary(display, DefaultRootWindow(display));
    if (primary != None) {
        return primary;
    }
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(display, res, res->outputs[i]);
        BOOL usable = info && info->connection == RR_Connected && info->crtc != None;
        if (info) {
            XRRFreeOutputInfo(info);
        }
        if (usable) {
            return res->outputs[i];
        }
    }
    return None;
}

static double scaleFromRandR(Display *display)
{
    XRRScreenResources *res =
        XRRGetScreenResourcesCurrent(display, DefaultRootWindow(display));
    if (!res) {
        return 0.0;
    }
    double scale = 0.0;
    RROutput output = primaryOrFirstConnectedOutput(display, res);
    XRROutputInfo *info = output != None ? XRRGetOutputInfo(display, res, output) : NULL;
    XRRCrtcInfo *crtc = (info && info->crtc != None)
        ? XRRGetCrtcInfo(display, res, info->crtc) : NULL;
    if (crtc) {
        // The mode keeps the panel's native orientation, like mm_width and
        // mm_height, while the crtc size is already rotated.
        for (int i = 0; i < res->nmode; i++) {
            if (res->modes[i].id == crtc->mode) {
                scale = [GSDisplayScaleHeuristic
                    recommendedScaleForPixelWidth:res->modes[i].width
                                      pixelHeight:res->modes[i].height
                                  millimeterWidth:info->mm_width
                                 millimeterHeight:info->mm_height];
                NSLog(@"[LoginWindow] Output %s: %lux%lu px, %lux%lu mm, recommended scale %.2f",
                      info->name, (unsigned long)res->modes[i].width,
                      (unsigned long)res->modes[i].height,
                      (unsigned long)info->mm_width, (unsigned long)info->mm_height, scale);
                break;
            }
        }
        XRRFreeCrtcInfo(crtc);
    }
    if (info) {
        XRRFreeOutputInfo(info);
    }
    XRRFreeScreenResources(res);
    return scale;
}

double LWRegisterRecommendedScale(Display *display)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"GSScaleFactor"] != nil) {
        return 0.0;
    }
    double scale = scaleFromRandR(display);
    if (scale <= 0.0) {
        return 0.0;
    }
    [defaults registerDefaults:
        [NSDictionary dictionaryWithObject:[NSNumber numberWithDouble:scale]
                                    forKey:@"GSScaleFactor"]];
    return scale;
}

BOOL LWSeedSystemScale(double scale)
{
    // libs-base looks for GlobalDefaults beside the GNUstep.conf it loaded,
    // which GNUSTEP_CONFIG_FILE may relocate (the isolated test sessions do).
    NSString *confFile = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"GNUSTEP_CONFIG_FILE"];
    NSString *prefs = [confFile length] > 0
        ? [confFile stringByDeletingLastPathComponent] : nil;
    if (prefs == nil) {
        NSArray *libs = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSSystemDomainMask, YES);
        if ([libs count] == 0) {
            NSLog(@"[LoginWindow] Cannot seed the system scale: no system library directory");
            return NO;
        }
        prefs = [[libs objectAtIndex:0] stringByAppendingPathComponent:@"Preferences"];
    }
    NSString *dir = [prefs stringByAppendingPathComponent:@"GlobalDefaults"];
    NSString *path = [dir stringByAppendingPathComponent:LWSystemDisplayDefaultsFileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        return YES;
    }
    // 0644: libs-base ignores a defaults file that group or others can write.
    NSDictionary *content = [NSDictionary dictionaryWithObject:
        [NSNumber numberWithDouble:scale] forKey:@"GSScaleFactor"];
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:content
        format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
    BOOL ok = data != nil && [fm createFileAtPath:path contents:data
        attributes:[NSDictionary dictionaryWithObject:
            [NSNumber numberWithUnsignedLong:0644] forKey:NSFilePosixPermissions]];
    if (!ok) {
        NSLog(@"[LoginWindow] Cannot write the system scale to %@ (read-only or no permission)", path);
    }
    return ok;
}
