/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "X11DisplayManager.h"
#import "DisplayLayout.h"
#import "DisplayArrangement.h"

#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <X11/extensions/Xrandr.h>
#import <stdlib.h>

NSString * const X11DisplayManagerErrorDomain = @"X11DisplayManagerErrorDomain";

/* X errors arrive asynchronously through a process-wide handler; while a
 * layout is applied, the errors of our own connection are collected here
 * so a refused step is reported instead of looking like success. */
static Display *trackedDisplay = NULL;
static int firstErrorCode = 0;
static unsigned char firstErrorRequest = 0;
static unsigned char firstErrorMinor = 0;
static int (*previousHandler)(Display *, XErrorEvent *) = NULL;

static int collectError(Display *dpy, XErrorEvent *ev)
{
    if (dpy != trackedDisplay) {
        return previousHandler ? previousHandler(dpy, ev) : 0;
    }
    if (firstErrorCode == 0) {
        firstErrorCode = ev->error_code;
        firstErrorRequest = ev->request_code;
        firstErrorMinor = ev->minor_code;
    }
    return 0;
}

static NSString *outputName(XRROutputInfo *oi)
{
    return [[[NSString alloc] initWithBytes:oi->name length:oi->nameLen
                                   encoding:NSUTF8StringEncoding] autorelease];
}

static XRRModeInfo *modeInfo(XRRScreenResources *res, RRMode mode)
{
    for (int j = 0; j < res->nmode; j++) {
        if (res->modes[j].id == mode) return &res->modes[j];
    }
    return NULL;
}

/* Same rate formula as xrandr. */
static double refreshOf(XRRModeInfo *mi)
{
    if (mi->hTotal == 0 || mi->vTotal == 0) return 0;
    double v = (double)mi->vTotal;
    if (mi->modeFlags & RR_DoubleScan) v *= 2;
    if (mi->modeFlags & RR_Interlace) v /= 2;
    return (double)mi->dotClock / ((double)mi->hTotal * v);
}

static NSArray *modesOfOutput(XRRScreenResources *res, XRROutputInfo *oi)
{
    NSMutableArray *modes = [NSMutableArray array];
    for (int k = 0; k < oi->nmode; k++) {
        XRRModeInfo *mi = modeInfo(res, oi->modes[k]);
        if (mi == NULL) continue;
        [modes addObject:[DisplayMode modeWithID:mi->id
                                           width:(int)mi->width
                                          height:(int)mi->height
                                         refresh:refreshOf(mi)
                                      interlaced:(mi->modeFlags & RR_Interlace) != 0
                                       preferred:k < oi->npreferred]];
    }
    return modes;
}

@implementation X11DisplayManager

- (id)init
{
    self = [super init];
    if (self) {
        _display = NULL;
        _screen = 0;
        _root = 0;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [super dealloc];
}

- (BOOL)connect
{
    if (_display) return YES;

    /* XOpenDisplay(NULL) reads DISPLAY itself; guessing ":0" when it is
     * unset would configure somebody else's screen. */
    _display = XOpenDisplay(NULL);
    if (!_display) {
        NSLog(@"X11DisplayManager: cannot open display '%s'", getenv("DISPLAY") ?: "");
        return NO;
    }
    int eventBase, errorBase;
    if (!XRRQueryExtension((Display *)_display, &eventBase, &errorBase)) {
        NSLog(@"X11DisplayManager: the X server has no RandR extension");
        XCloseDisplay((Display *)_display);
        _display = NULL;
        return NO;
    }
    _screen = DefaultScreen((Display *)_display);
    _root = RootWindow((Display *)_display, _screen);
    return YES;
}

- (void)disconnect
{
    if (_display) {
        XCloseDisplay((Display *)_display);
        _display = NULL;
    }
}

- (BOOL)isAvailable
{
    return [self connect];
}

#pragma mark - Query

- (NSData *)edidOfOutput:(RROutput)output
{
    Display *dpy = (Display *)_display;
    Atom edidAtom = XInternAtom(dpy, RR_PROPERTY_RANDR_EDID, True);
    if (edidAtom == None) return nil;
    Atom type;
    int format;
    unsigned long count, after;
    unsigned char *data = NULL;
    NSData *result = nil;
    if (XRRGetOutputProperty(dpy, output, edidAtom, 0, 64, False, False,
                             AnyPropertyType, &type, &format, &count, &after,
                             &data) == Success) {
        if (type == XA_INTEGER && format == 8 && count >= 128) {
            result = [NSData dataWithBytes:data length:count];
        }
    }
    if (data) XFree(data);
    return result;
}

- (DisplayLayout *)currentLayoutProbingOutputs:(BOOL)probe
{
    if (![self connect]) return nil;
    Display *dpy = (Display *)_display;

    XRRScreenResources *res = probe ? XRRGetScreenResources(dpy, _root)
                                    : XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) return nil;
    RROutput primaryID = XRRGetOutputPrimary(dpy, _root);

    NSMutableArray *outputs = [NSMutableArray array];
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        if (oi->connection != RR_Connected) {
            XRRFreeOutputInfo(oi);
            continue;
        }

        DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
        [o setName:outputName(oi)];
        [o setConnected:YES];
        [o setModes:modesOfOutput(res, oi)];
        [o setWidthMM:(int)oi->mm_width];
        [o setHeightMM:(int)oi->mm_height];
        NSMutableArray *possible = [NSMutableArray array];
        for (int c = 0; c < oi->ncrtc; c++) {
            [possible addObject:[NSNumber numberWithUnsignedLong:oi->crtcs[c]]];
        }
        [o setPossibleCrtcs:possible];

        NSData *edid = [self edidOfOutput:res->outputs[i]];
        [o setEdidIdentity:DisplayEDIDIdentity(edid)];
        [o setMonitorName:DisplayEDIDMonitorName(edid)];

        XRRCrtcInfo *ci = oi->crtc ? XRRGetCrtcInfo(dpy, res, oi->crtc) : NULL;
        XRRModeInfo *mi = ci ? modeInfo(res, ci->mode) : NULL;
        if (ci && mi) {
            [o setEnabled:YES];
            [o setCrtc:oi->crtc];
            [o setX:ci->x];
            [o setY:ci->y];
            [o setModeWidth:(int)mi->width];
            [o setModeHeight:(int)mi->height];
            [o setModeRefresh:refreshOf(mi)];
            [o setRotation:ci->rotation];
            XRRCrtcTransformAttributes *attr = NULL;
            if (XRRGetCrtcTransform(dpy, oi->crtc, &attr) && attr) {
                [o setTransformScaleX:XFixedToDouble(attr->currentTransform.matrix[0][0])];
                [o setTransformScaleY:XFixedToDouble(attr->currentTransform.matrix[1][1])];
                XFree(attr);
            }
            [o setPrimary:(res->outputs[i] == primaryID)];
        } else {
            /* Connected but dark (a monitor plugged in after X started):
             * offer its native mode until the user picks one. */
            [o setEnabled:NO];
            DisplayMode *pm = [o preferredMode];
            [o setModeWidth:[pm width]];
            [o setModeHeight:[pm height]];
            [o setModeRefresh:[pm refresh]];
        }
        if (ci) XRRFreeCrtcInfo(ci);
        XRRFreeOutputInfo(oi);
        [outputs addObject:o];
    }
    XRRFreeScreenResources(res);

    DisplayLayout *layout = [DisplayLayout layoutWithOutputs:outputs];
    if ([layout primaryOutput] == nil && [[layout enabledOutputs] count] > 0) {
        /* Without a RandR primary, X clients take the first enabled output
         * as the main one; show it that way so applying makes it explicit. */
        [[[layout enabledOutputs] objectAtIndex:0] setPrimary:YES];
    }
    return layout;
}

#pragma mark - Apply

- (NSError *)errorWithText:(NSString *)text
{
    return [NSError errorWithDomain:X11DisplayManagerErrorDomain code:1
                           userInfo:[NSDictionary dictionaryWithObject:text
                                                                forKey:NSLocalizedDescriptionKey]];
}

- (NSSize)screenSize
{
    /* DisplayWidth()/DisplayHeight() are cached per connection and not
     * updated when another client resizes the screen; ask the server. */
    Window rootReturn;
    int x, y;
    unsigned int w = 0, h = 0, border, depth;
    XGetGeometry((Display *)_display, _root, &rootReturn, &x, &y, &w, &h, &border, &depth);
    return NSMakeSize(w, h);
}

- (void)setScreenSize:(NSSize)size
{
    /* 96 DPI, so the reported physical size follows the pixel size the
     * way it always did in this pane. */
    int w = (int)size.width, h = (int)size.height;
    XRRSetScreenSize((Display *)_display, _root, w, h,
                     (int)(w * 25.4 / 96.0), (int)(h * 25.4 / 96.0));
}

- (BOOL)crtcHasTransform:(RRCrtc)crtc
{
    XRRCrtcTransformAttributes *attr = NULL;
    BOOL scaled = NO;
    if (XRRGetCrtcTransform((Display *)_display, crtc, &attr) && attr) {
        XTransform *t = &attr->currentTransform;
        scaled = t->matrix[0][0] != XDoubleToFixed(1.0) || t->matrix[1][1] != XDoubleToFixed(1.0)
            || t->matrix[0][1] != 0 || t->matrix[1][0] != 0;
        XFree(attr);
    }
    return scaled;
}

- (BOOL)applyLayout:(DisplayLayout *)layout error:(NSError **)error
{
    if (![self connect]) {
        if (error) *error = [self errorWithText:@"The X display cannot be opened."];
        return NO;
    }
    Display *dpy = (Display *)_display;
    NSArray *enabled = [layout enabledOutputs];
    if ([enabled count] == 0) {
        if (error) *error = [self errorWithText:@"At least one display must stay on."];
        return NO;
    }

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) {
        if (error) *error = [self errorWithText:@"The display configuration cannot be read."];
        return NO;
    }

    /* Server state per output name. */
    NSMutableDictionary *outputIDs = [NSMutableDictionary dictionary];
    NSMutableDictionary *serverModes = [NSMutableDictionary dictionary];
    NSMutableArray *requests = [NSMutableArray array];
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *name = outputName(oi);
        [outputIDs setObject:[NSNumber numberWithUnsignedLong:res->outputs[i]] forKey:name];
        [serverModes setObject:modesOfOutput(res, oi) forKey:name];
        DisplayOutput *wanted = [layout outputNamed:name];
        if (wanted && [wanted enabled]) {
            NSMutableArray *possible = [NSMutableArray array];
            for (int c = 0; c < oi->ncrtc; c++) {
                [possible addObject:[NSNumber numberWithUnsignedLong:oi->crtcs[c]]];
            }
            [requests addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                name, @"name",
                [NSNumber numberWithUnsignedLong:oi->crtc], @"crtc",
                possible, @"possible", nil]];
        }
        XRRFreeOutputInfo(oi);
    }

    NSString *problem = nil;
    for (DisplayOutput *o in enabled) {
        if ([outputIDs objectForKey:[o name]] == nil) {
            problem = [NSString stringWithFormat:@"Display %@ is not connected.", [o name]];
            break;
        }
    }
    NSString *failed = nil;
    NSDictionary *crtcs = problem ? nil : DisplayAssignCrtcs(requests, &failed);
    if (!problem && crtcs == nil) {
        problem = [NSString stringWithFormat:
            @"No free display controller (CRTC) can drive %@.", failed];
    }

    NSMutableDictionary *modeIDs = [NSMutableDictionary dictionary];
    NSMutableArray *frames = [NSMutableArray array];
    for (DisplayOutput *o in enabled) {
        if (problem) break;
        DisplayMode *m = DisplaySelectMode([serverModes objectForKey:[o name]],
                                           [o modeWidth], [o modeHeight], [o modeRefresh]);
        if (m == nil) {
            problem = [NSString stringWithFormat:@"Display %@ does not support %dx%d.",
                       [o name], [o modeWidth], [o modeHeight]];
            break;
        }
        [modeIDs setObject:[NSNumber numberWithUnsignedLong:[m modeID]] forKey:[o name]];
        [frames addObject:[NSValue valueWithRect:[o frame]]];
    }

    NSSize current = [self screenSize];
    DisplayScreenSizePlan plan = DisplayPlanScreenSize(current, frames);
    if (!problem) {
        int minW, minH, maxW, maxH;
        XRRGetScreenSizeRange(dpy, _root, &minW, &minH, &maxW, &maxH);
        if (plan.grow.width > maxW || plan.grow.height > maxH) {
            problem = [NSString stringWithFormat:
                @"The arrangement needs a %.0fx%.0f screen; this X server allows at most %dx%d.",
                plan.grow.width, plan.grow.height, maxW, maxH];
        } else if (plan.final.width < minW || plan.final.height < minH) {
            problem = [NSString stringWithFormat:
                @"The arrangement is smaller than the minimum screen size %dx%d.", minW, minH];
        }
    }
    if (problem) {
        XRRFreeScreenResources(res);
        if (error) *error = [self errorWithText:problem];
        return NO;
    }

    NSSet *keptCrtcs = [NSSet setWithArray:[crtcs allValues]];
    BOOL refused = NO;

    /* Nobody may see, or act on, the half-configured screen in between. */
    XGrabServer(dpy);
    XSync(dpy, False);
    trackedDisplay = dpy;
    firstErrorCode = 0;
    previousHandler = XSetErrorHandler(collectError);

    /* 1. Switch off every CRTC that is not part of the new layout, so its
     *    old size cannot keep the screen from shrinking and its outputs
     *    (turned off, unplugged, moved elsewhere) go dark. */
    for (int c = 0; c < res->ncrtc; c++) {
        if ([keptCrtcs containsObject:[NSNumber numberWithUnsignedLong:res->crtcs[c]]]) continue;
        XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, res->crtcs[c]);
        if (ci && ci->mode != None) {
            if (XRRSetCrtcConfig(dpy, res, res->crtcs[c], CurrentTime, 0, 0, None,
                                 RR_Rotate_0, NULL, 0) != RRSetConfigSuccess) {
                refused = YES;
            }
        }
        if (ci) XRRFreeCrtcInfo(ci);
    }

    /* 2. Grow first: a CRTC must lie inside the screen when it is set. */
    if (!NSEqualSizes(plan.grow, current)) [self setScreenSize:plan.grow];

    /* 3. Every enabled output on its CRTC, with its transform. */
    for (DisplayOutput *o in enabled) {
        RRCrtc crtc = [[crtcs objectForKey:[o name]] unsignedLongValue];
        RROutput out = [[outputIDs objectForKey:[o name]] unsignedLongValue];
        RRMode mode = [[modeIDs objectForKey:[o name]] unsignedLongValue];

        /* Only touch the transform when one is wanted or must be undone:
         * drivers without transform support refuse even the identity. */
        if ([o hasTransform] || [self crtcHasTransform:crtc]) {
            XTransform t;
            memset(&t, 0, sizeof(t));
            t.matrix[0][0] = DisplayFixedFromDouble([o transformScaleX]);
            t.matrix[1][1] = DisplayFixedFromDouble([o transformScaleY]);
            t.matrix[2][2] = XDoubleToFixed(1.0);
            /* The transform takes effect with the next CRTC configuration;
             * bilinear keeps a scaled mirror readable. */
            char *filter = [o hasTransform] ? "bilinear" : "nearest";
            XRRSetCrtcTransform(dpy, crtc, &t, filter, NULL, 0);
        }

        if (XRRSetCrtcConfig(dpy, res, crtc, CurrentTime, [o x], [o y], mode,
                             (Rotation)[o rotation], &out, 1) != RRSetConfigSuccess) {
            refused = YES;
        }
    }

    /* 4. Shrink to the new layout once nothing lies outside it. */
    if (!NSEqualSizes(plan.final, plan.grow)) [self setScreenSize:plan.final];

    DisplayOutput *primary = [layout primaryOutput];
    if (primary) {
        XRRSetOutputPrimary(dpy, _root,
                            [[outputIDs objectForKey:[primary name]] unsignedLongValue]);
    }

    XUngrabServer(dpy);
    XSync(dpy, False);
    XSetErrorHandler(previousHandler);
    trackedDisplay = NULL;
    XRRFreeScreenResources(res);

    if (firstErrorCode != 0 || refused) {
        if (error) {
            char text[128] = "";
            NSString *why;
            if (firstErrorCode) XGetErrorText(dpy, firstErrorCode, text, sizeof(text));
            if (firstErrorCode && firstErrorMinor == X_RRSetCrtcTransform) {
                why = @"The graphics driver cannot scale a display, so these displays "
                      @"can only mirror at a resolution they all support.";
            } else if (firstErrorCode) {
                why = [NSString stringWithFormat:
                    @"The X server refused the display configuration (%s, request %d.%d).",
                    text, firstErrorRequest, firstErrorMinor];
            } else {
                why = @"The X server refused the display configuration.";
            }
            *error = [self errorWithText:why];
        }
        return NO;
    }
    return YES;
}

@end
