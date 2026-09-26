/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MousePreferences.h"

NSString *const MousePreferencesDomain = @"MousePreferences";

NSString *const MousePreferencesSpeed = @"Speed";
NSString *const MousePreferencesNaturalScrolling = @"NaturalScrolling";
NSString *const MousePreferencesLeftHanded = @"LeftHanded";
NSString *const MousePreferencesScrollSpeed = @"ScrollSpeed";
NSString *const MousePreferencesCurveProfile = @"CurveProfile";
NSString *const MousePreferencesCurvePrecision = @"CurvePrecision";
NSString *const MousePreferencesCurveStart = @"CurveStart";
NSString *const MousePreferencesCurveEnd = @"CurveEnd";
NSString *const MousePreferencesCurveFast = @"CurveFast";

static const PointerDeviceKind kAllKinds[] = {
    PointerDeviceKindMouse, PointerDeviceKindTouchpad, PointerDeviceKindTrackpoint,
};

@implementation MousePreferences

+ (NSString *)keyPrefixForKind:(PointerDeviceKind)kind
{
    switch (kind) {
    case PointerDeviceKindMouse:
        return @"mouse";
    case PointerDeviceKindTouchpad:
        return @"trackpad";
    case PointerDeviceKindTrackpoint:
        return @"trackpoint";
    case PointerDeviceKindNone:
        break;
    }
    [NSException raise:NSInvalidArgumentException format:@"no preferences for device kind %ld", (long)kind];
    return nil;
}

+ (NSString *)key:(NSString *)setting forKind:(PointerDeviceKind)kind
{
    return [[self keyPrefixForKind:kind] stringByAppendingString:setting];
}

+ (NSArray *)curveKeysForKind:(PointerDeviceKind)kind
{
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *s in @[MousePreferencesCurveProfile, MousePreferencesCurvePrecision,
                          MousePreferencesCurveStart, MousePreferencesCurveEnd,
                          MousePreferencesCurveFast]) {
        [keys addObject:[self key:s forKind:kind]];
    }
    return keys;
}

+ (NSDictionary *)migratedDomain:(NSDictionary *)domain
{
    NSMutableDictionary *out = [domain mutableCopy];
    NSDictionary *shared = @{
        @"naturalScrolling" : MousePreferencesNaturalScrolling,
        @"leftHanded" : MousePreferencesLeftHanded,
    };
    for (NSString *oldKey in shared) {
        id value = [out objectForKey:oldKey];
        if (value == nil) {
            continue;
        }
        for (NSUInteger i = 0; i < sizeof(kAllKinds) / sizeof(kAllKinds[0]); i++) {
            NSString *key = [self key:[shared objectForKey:oldKey] forKind:kAllKinds[i]];
            if ([out objectForKey:key] == nil) {
                [out setObject:value forKey:key];
            }
        }
        [out removeObjectForKey:oldKey];
    }
    /* The only curve there was belonged to the trackpad. */
    NSDictionary *curve = @{
        @"curveProfile" : MousePreferencesCurveProfile,
        @"curvePrecision" : MousePreferencesCurvePrecision,
        @"curveStart" : MousePreferencesCurveStart,
        @"curveEnd" : MousePreferencesCurveEnd,
        @"curveFast" : MousePreferencesCurveFast,
    };
    for (NSString *oldKey in curve) {
        id value = [out objectForKey:oldKey];
        if (value == nil) {
            continue;
        }
        NSString *key = [self key:[curve objectForKey:oldKey] forKind:PointerDeviceKindTouchpad];
        if ([out objectForKey:key] == nil) {
            [out setObject:value forKey:key];
        }
        [out removeObjectForKey:oldKey];
    }
    return out;
}

static BOOL NumberIn(NSDictionary *domain, NSString *key, double *out)
{
    id value = [domain objectForKey:key];
    if (![value isKindOfClass:[NSNumber class]] && ![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    *out = [value doubleValue];
    return YES;
}

+ (BOOL)curve:(AccelerationCurve *)curve forKind:(PointerDeviceKind)kind
     inDomain:(NSDictionary *)domain
{
    AccelerationCurve c;
    if (!NumberIn(domain, [self key:MousePreferencesCurvePrecision forKind:kind], &c.precision)
        || !NumberIn(domain, [self key:MousePreferencesCurveStart forKind:kind], &c.start)
        || !NumberIn(domain, [self key:MousePreferencesCurveEnd forKind:kind], &c.end)
        || !NumberIn(domain, [self key:MousePreferencesCurveFast forKind:kind], &c.fast)) {
        return NO;
    }
    *curve = c;
    return YES;
}

+ (NSDictionary *)currentDomain
{
    NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
        persistentDomainForName:MousePreferencesDomain];
    return [self migratedDomain:(domain ? domain : @{})];
}

+ (void)setObject:(id)value forKey:(NSString *)key
{
    NSMutableDictionary *domain = [[self currentDomain] mutableCopy];
    [domain setObject:value forKey:key];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:MousePreferencesDomain];
    [defaults synchronize];
}

@end
