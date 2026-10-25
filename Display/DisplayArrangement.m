/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayArrangement.h"
#import "DisplayLayout.h"

#import <math.h>

const double DisplayScaleFactorMinimum = 1.0;
/* HiDPI laptop panels (13 inch 4K) need more than 2.0 to be readable. */
const double DisplayScaleFactorMaximum = 3.0;
const NSUInteger DisplayScaleFactorStepCount = 7;

static const double scaleSteps[] = {1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0};

double DisplayScaleFactorAtStep(NSUInteger index)
{
    if (index >= DisplayScaleFactorStepCount) index = DisplayScaleFactorStepCount - 1;
    return scaleSteps[index];
}

NSUInteger DisplayScaleFactorStepIndex(double factor)
{
    NSUInteger best = 0;
    for (NSUInteger i = 1; i < DisplayScaleFactorStepCount; i++) {
        if (fabs(scaleSteps[i] - factor) < fabs(scaleSteps[best] - factor)) best = i;
    }
    return best;
}

double DisplayClampScaleFactor(double factor)
{
    return scaleSteps[DisplayScaleFactorStepIndex(factor)];
}

DisplayMode *DisplaySelectMode(NSArray *modes, int width, int height,
                               double refresh)
{
    NSMutableArray *sized = [NSMutableArray array];
    BOOL anyProgressive = NO;
    for (DisplayMode *m in modes) {
        if ([m width] == width && [m height] == height) {
            [sized addObject:m];
            if (![m interlaced]) anyProgressive = YES;
        }
    }
    if (anyProgressive) {
        NSMutableArray *progressive = [NSMutableArray array];
        for (DisplayMode *m in sized) {
            if (![m interlaced]) [progressive addObject:m];
        }
        sized = progressive;
    }
    if ([sized count] == 0) return nil;

    if (refresh > 0) {
        DisplayMode *closest = nil;
        for (DisplayMode *m in sized) {
            if (closest == nil
                || fabs([m refresh] - refresh) < fabs([closest refresh] - refresh)) {
                closest = m;
            }
        }
        if (fabs([closest refresh] - refresh) <= 0.5) return closest;
    }
    for (DisplayMode *m in sized) {
        if ([m preferred]) return m;
    }
    DisplayMode *fastest = nil;
    for (DisplayMode *m in sized) {
        if (fastest == nil || [m refresh] > [fastest refresh]) fastest = m;
    }
    return fastest;
}

NSString *DisplayCommonResolution(NSArray *modeLists)
{
    if ([modeLists count] == 0) return nil;
    NSMutableSet *common = nil;
    for (NSArray *list in modeLists) {
        NSMutableSet *sizes = [NSMutableSet set];
        for (DisplayMode *m in list) [sizes addObject:[m sizeString]];
        if (common == nil) common = sizes;
        else [common intersectSet:sizes];
    }
    NSString *best = nil;
    long bestArea = -1;
    int bestWidth = -1;
    for (NSString *s in common) {
        NSArray *parts = [s componentsSeparatedByString:@"x"];
        int w = [[parts objectAtIndex:0] intValue];
        int h = [[parts objectAtIndex:1] intValue];
        long area = (long)w * h;
        if (area > bestArea || (area == bestArea && w > bestWidth)) {
            best = s;
            bestArea = area;
            bestWidth = w;
        }
    }
    return best;
}

int DisplayFixedFromDouble(double value)
{
    /* Rounding down keeps target/length scales from overshooting: the server
     * rounds the transformed bounds up, so a fixed value one unit too large
     * makes a mirrored output a pixel larger than the primary.  Scales here
     * are target/length ratios whose exact 16.16 value is either an integer
     * or at least 1/65536 away from one, so the 1e-9 only absorbs the double
     * rounding error of an exact integer. */
    return (int)floor(value * 65536.0 + 1e-9);
}

int DisplayTransformedExtent(int length, double scale)
{
    /* Same arithmetic as the server: 16.16 fixed point, bounds rounded up. */
    long long scaled = (long long)length * DisplayFixedFromDouble(scale);
    return (int)((scaled + 65535) / 65536);
}

#pragma mark - Arrangement

static BOOL rectsOverlap(NSRect a, NSRect b)
{
    return NSMinX(a) < NSMaxX(b) && NSMinX(b) < NSMaxX(a)
        && NSMinY(a) < NSMaxY(b) && NSMinY(b) < NSMaxY(a);
}

static BOOL overlapsAny(NSRect r, NSArray *placed)
{
    for (NSValue *v in placed) {
        if (rectsOverlap(r, [v rectValue])) return YES;
    }
    return NO;
}

static CGFloat clampf(CGFloat v, CGFloat lo, CGFloat hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Along the shared edge, align start or end edges that are within `snap`. */
static CGFloat alignAlong(CGFloat pos, CGFloat len, CGFloat otherPos,
                          CGFloat otherLen, CGFloat snap)
{
    if (fabs(pos - otherPos) <= snap) return otherPos;
    if (fabs((pos + len) - (otherPos + otherLen)) <= snap) return otherPos + otherLen - len;
    return pos;
}

/* The free spot touching one of `placed` that is closest to `r`. */
static NSRect snapToPlaced(NSRect r, NSArray *placed, CGFloat snap)
{
    if ([placed count] == 0) return r;
    CGFloat w = NSWidth(r), h = NSHeight(r);
    NSRect best = r;
    CGFloat bestDistance = CGFLOAT_MAX;

    for (NSValue *v in placed) {
        NSRect p = [v rectValue];
        /* Keep at least one pixel of shared edge so the outputs touch. */
        CGFloat ys = alignAlong(clampf(NSMinY(r), NSMinY(p) - h + 1, NSMaxY(p) - 1),
                                h, NSMinY(p), NSHeight(p), snap);
        CGFloat xs = alignAlong(clampf(NSMinX(r), NSMinX(p) - w + 1, NSMaxX(p) - 1),
                                w, NSMinX(p), NSWidth(p), snap);
        NSRect candidates[4] = {
            NSMakeRect(NSMaxX(p), ys, w, h),      /* right */
            NSMakeRect(NSMinX(p) - w, ys, w, h),  /* left */
            NSMakeRect(xs, NSMinY(p) - h, w, h),  /* above */
            NSMakeRect(xs, NSMaxY(p), w, h),      /* below */
        };
        for (int i = 0; i < 4; i++) {
            NSRect c = candidates[i];
            if (overlapsAny(c, placed)) continue;
            CGFloat dx = NSMinX(c) - NSMinX(r), dy = NSMinY(c) - NSMinY(r);
            CGFloat d = dx * dx + dy * dy;
            if (d < bestDistance) {
                bestDistance = d;
                best = c;
            }
        }
    }
    return best;
}

NSDictionary *DisplayArrangeRects(NSDictionary *proposed, NSString *primary,
                                  NSString *moved, CGFloat snap)
{
    NSMutableArray *order = [NSMutableArray arrayWithArray:
        [[proposed allKeys] sortedArrayUsingSelector:@selector(compare:)]];
    NSPoint anchor = NSZeroPoint;
    if (primary && [proposed objectForKey:primary]) {
        anchor = [[proposed objectForKey:primary] rectValue].origin;
    }
    /* Outputs the user did not touch keep their place: the primary first,
     * then by distance from it, so a gap left by a moved output closes from
     * the primary outwards.  The moved output comes last. */
    [order sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL am = [a isEqualToString:moved ? moved : @""];
        BOOL bm = [b isEqualToString:moved ? moved : @""];
        if (am != bm) return am ? NSOrderedDescending : NSOrderedAscending;
        BOOL ap = [a isEqualToString:primary ? primary : @""];
        BOOL bp = [b isEqualToString:primary ? primary : @""];
        if (ap != bp) return ap ? NSOrderedAscending : NSOrderedDescending;
        NSPoint pa = [[proposed objectForKey:a] rectValue].origin;
        NSPoint pb = [[proposed objectForKey:b] rectValue].origin;
        CGFloat da = hypot(pa.x - anchor.x, pa.y - anchor.y);
        CGFloat db = hypot(pb.x - anchor.x, pb.y - anchor.y);
        if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];

    NSMutableArray *placed = [NSMutableArray array];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in order) {
        NSRect r = [[proposed objectForKey:name] rectValue];
        r.origin.x = round(r.origin.x);
        r.origin.y = round(r.origin.y);
        r = snapToPlaced(r, placed, snap);
        [placed addObject:[NSValue valueWithRect:r]];
        [result setObject:[NSValue valueWithRect:r] forKey:name];
    }

    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    for (NSValue *v in placed) {
        minX = MIN(minX, NSMinX([v rectValue]));
        minY = MIN(minY, NSMinY([v rectValue]));
    }
    for (NSString *name in [result allKeys]) {
        NSRect r = NSOffsetRect([[result objectForKey:name] rectValue], -minX, -minY);
        [result setObject:[NSValue valueWithRect:r] forKey:name];
    }
    return result;
}

#pragma mark - View mapping

DisplayViewMapping DisplayViewMappingMake(NSRect modelBounds, NSRect viewBounds,
                                          CGFloat margin, CGFloat maxScale)
{
    DisplayViewMapping m;
    CGFloat availW = NSWidth(viewBounds) - 2 * margin;
    CGFloat availH = NSHeight(viewBounds) - 2 * margin;
    CGFloat scale = maxScale;
    if (NSWidth(modelBounds) > 0) scale = MIN(scale, availW / NSWidth(modelBounds));
    if (NSHeight(modelBounds) > 0) scale = MIN(scale, availH / NSHeight(modelBounds));
    m.modelBounds = modelBounds;
    m.scale = scale;
    m.viewOrigin = NSMakePoint(
        NSMinX(viewBounds) + (NSWidth(viewBounds) - NSWidth(modelBounds) * scale) / 2,
        NSMinY(viewBounds) + (NSHeight(viewBounds) - NSHeight(modelBounds) * scale) / 2);
    return m;
}

NSRect DisplayViewRectForModelRect(NSRect r, DisplayViewMapping m)
{
    /* The view is y-up, the screen y-down: measure from the bottom edge. */
    return NSMakeRect(m.viewOrigin.x + (NSMinX(r) - NSMinX(m.modelBounds)) * m.scale,
                      m.viewOrigin.y + (NSMaxY(m.modelBounds) - NSMaxY(r)) * m.scale,
                      NSWidth(r) * m.scale, NSHeight(r) * m.scale);
}

NSPoint DisplayModelOriginForViewRect(NSRect v, DisplayViewMapping m)
{
    return NSMakePoint(
        round(NSMinX(m.modelBounds) + (NSMinX(v) - m.viewOrigin.x) / m.scale),
        round(NSMaxY(m.modelBounds) - (NSMaxY(v) - m.viewOrigin.y) / m.scale));
}

#pragma mark - Screen size and CRTCs

DisplayScreenSizePlan DisplayPlanScreenSize(NSSize current, NSArray *frames)
{
    DisplayScreenSizePlan plan;
    CGFloat w = 0, h = 0;
    for (NSValue *v in frames) {
        w = MAX(w, NSMaxX([v rectValue]));
        h = MAX(h, NSMaxY([v rectValue]));
    }
    plan.final = NSMakeSize(w, h);
    plan.grow = NSMakeSize(MAX(current.width, w), MAX(current.height, h));
    return plan;
}

NSDictionary *DisplayAssignCrtcs(NSArray *requests, NSString **failed)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableSet *taken = [NSMutableSet set];
    NSMutableArray *needing = [NSMutableArray array];

    for (NSDictionary *req in requests) {
        NSNumber *crtc = [req objectForKey:@"crtc"];
        if ([crtc unsignedLongValue] != 0 && ![taken containsObject:crtc]) {
            [taken addObject:crtc];
            [result setObject:crtc forKey:[req objectForKey:@"name"]];
        } else {
            [needing addObject:req];
        }
    }
    for (NSDictionary *req in needing) {
        NSNumber *chosen = nil;
        for (NSNumber *c in [req objectForKey:@"possible"]) {
            if (![taken containsObject:c]) {
                chosen = c;
                break;
            }
        }
        if (chosen == nil) {
            if (failed) *failed = [req objectForKey:@"name"];
            return nil;
        }
        [taken addObject:chosen];
        [result setObject:chosen forKey:[req objectForKey:@"name"]];
    }
    return result;
}
