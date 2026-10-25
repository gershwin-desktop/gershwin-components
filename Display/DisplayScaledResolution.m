/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "DisplayScaledResolution.h"
#import "DisplayArrangement.h"

#import <math.h>

@interface DisplayScaledResolution ()
- (instancetype)initWithModeWidth:(int)modeWidth height:(int)modeHeight
                      globalScale:(double)globalScale
                 framebufferWidth:(int)fbWidth height:(int)fbHeight
                   effectiveScale:(double)effective isDefault:(BOOL)isDefault;
@end

@implementation DisplayScaledResolution

@synthesize logicalWidth = _logicalWidth, logicalHeight = _logicalHeight,
    framebufferWidth = _framebufferWidth, framebufferHeight = _framebufferHeight,
    transformScaleX = _transformScaleX, transformScaleY = _transformScaleY,
    effectiveScale = _effectiveScale, isDefault = _isDefault;

- (instancetype)initWithModeWidth:(int)modeWidth height:(int)modeHeight
                      globalScale:(double)globalScale
                 framebufferWidth:(int)fbWidth height:(int)fbHeight
                   effectiveScale:(double)effective isDefault:(BOOL)isDefault
{
    self = [super init];
    if (self) {
        _framebufferWidth = fbWidth;
        _framebufferHeight = fbHeight;
        _logicalWidth = (int)lround(fbWidth / globalScale);
        _logicalHeight = (int)lround(fbHeight / globalScale);
        /* Per axis from the integer sizes, not global / effective: the
         * server rounds the transformed bounds, and only an exact ratio
         * makes them the framebuffer size. */
        _transformScaleX = isDefault ? 1.0 : (double)fbWidth / modeWidth;
        _transformScaleY = isDefault ? 1.0 : (double)fbHeight / modeHeight;
        _effectiveScale = effective;
        _isDefault = isDefault;
    }
    return self;
}

- (NSString *)title
{
    NSString *size = [NSString stringWithFormat:@"%dx%d", _logicalWidth, _logicalHeight];
    return _isDefault ? [size stringByAppendingString:@" (Default)"] : size;
}

@end

/* Beyond these the picture gets either too soft (the server enlarges a
 * small framebuffer) or too expensive for what it shows (four times the
 * pixels, scaled down), the range other desktops offer as well. */
static const double kMinimumTransform = 0.5;
static const double kMaximumTransform = 2.0;
/* The same floor as the scale recommendation: a desktop lower than this has
 * no room for ordinary windows. */
static const int kMinimumLogicalHeight = 720;

static int nearestEven(double value)
{
    return 2 * (int)lround(value / 2.0);
}

NSArray *DisplayScaledResolutions(int modeWidth, int modeHeight, double globalScale,
                                  int maxScreenWidth, int maxScreenHeight)
{
    NSMutableArray *result = [NSMutableArray array];
    if (modeWidth <= 0 || modeHeight <= 0 || globalScale <= 0) return result;

    double global = DisplayClampScaleFactor(globalScale);
    for (NSUInteger i = DisplayScaleFactorStepCount; i-- > 0;) {
        double effective = DisplayScaleFactorAtStep(i);
        if (fabs(effective - global) < 1e-9) {
            [result addObject:[[[DisplayScaledResolution alloc]
                initWithModeWidth:modeWidth height:modeHeight globalScale:global
                 framebufferWidth:modeWidth height:modeHeight
                   effectiveScale:effective isDefault:YES] autorelease]];
            continue;
        }
        double t = global / effective;
        if (t < kMinimumTransform - 1e-9 || t > kMaximumTransform + 1e-9) continue;
        /* Even framebuffer sizes: drivers scan out and scale even sizes
         * best, and at factor 2 the points stay whole numbers. */
        int fbWidth = nearestEven(modeWidth * t);
        int fbHeight = nearestEven(modeHeight * t);
        if (lround(fbHeight / global) < kMinimumLogicalHeight) continue;
        if ((maxScreenWidth > 0 && fbWidth > maxScreenWidth)
            || (maxScreenHeight > 0 && fbHeight > maxScreenHeight)) continue;
        [result addObject:[[[DisplayScaledResolution alloc]
            initWithModeWidth:modeWidth height:modeHeight globalScale:global
             framebufferWidth:fbWidth height:fbHeight
               effectiveScale:effective isDefault:NO] autorelease]];
    }
    return result;
}

DisplayScaledResolution *DisplayScaledResolutionForTransform(NSArray *options,
                                                             double transformScaleX,
                                                             double transformScaleY)
{
    /* The server stores 16.16 fixed point, so a value read back is up to
     * 1/65536 below the one sent. */
    const double tolerance = 2.0 / 65536.0;
    for (DisplayScaledResolution *r in options) {
        if (fabs([r transformScaleX] - transformScaleX) <= tolerance
            && fabs([r transformScaleY] - transformScaleY) <= tolerance) {
            return r;
        }
    }
    return nil;
}
