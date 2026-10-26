/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWDisplayScale.h"
#import "DisplayScaleHeuristic.h"
#import "DisplaySystemDefaults.h"
#include <X11/extensions/Xrandr.h>

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
                scale = [DisplayScaleHeuristic
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

double LWRegisterRecommendedScale(Display *display, BOOL updateSystemFile)
{
    NSString *path = DisplaySystemDefaultsPath();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    DisplaySystemScaleState state = DisplaySystemScaleStateAtPath(path);
    if (state == DisplaySystemScaleConfigured) {
        return 0.0;
    }
    // Without our own file, a scale that is set anywhere else is the user's.
    if (state == DisplaySystemScaleAbsent &&
        [defaults objectForKey:@"GSScaleFactor"] != nil) {
        return 0.0;
    }
    double scale = scaleFromRandR(display);
    if (scale <= 0.0) {
        return 0.0;
    }
    // The argument domain outranks the config domain, where the previous
    // start's recommendation (read at process start) would otherwise win.
    NSMutableDictionary *args = [NSMutableDictionary dictionaryWithDictionary:
        [defaults volatileDomainForName:NSArgumentDomain]];
    [args setObject:[NSNumber numberWithDouble:scale] forKey:@"GSScaleFactor"];
    [defaults removeVolatileDomainForName:NSArgumentDomain];
    [defaults setVolatileDomain:args forName:NSArgumentDomain];
    NSString *problem = nil;
    if (updateSystemFile && !DisplayWriteRecommendedScale(path, scale, &problem)) {
        // LoginWindow still uses the scale itself; only new users miss it.
        NSLog(@"[LoginWindow] Cannot save the recommended scale for new users: %@", problem);
    }
    return scale;
}
