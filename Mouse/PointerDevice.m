/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "PointerDevice.h"

/* Indexed like libinput's "Accel Profiles Available" and "Accel Profile
 * Enabled" flags. */
static NSString *const kProfiles[] = { @"system", @"flat", @"custom" };
static const NSUInteger kProfileCount = 3;

@implementation PointerDevice

- (instancetype)initWithID:(NSString *)deviceID
                      name:(NSString *)name
                      kind:(PointerDeviceKind)kind
                properties:(NSDictionary *)properties
                unitsPerMM:(double)unitsPerMM
{
    self = [super init];
    if (self) {
        _deviceID = [deviceID copy];
        _name = [name copy];
        _kind = kind;
        _properties = [properties copy];
        _unitsPerMM = unitsPerMM;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<PointerDevice %@ '%@' kind %ld>",
                     _deviceID, _name, (long)_kind];
}

- (NSString *)libinputValue:(NSString *)name
{
    return [_properties objectForKey:[@"libinput " stringByAppendingString:name]];
}

static NSArray *Flags(NSString *value)
{
    NSMutableArray *flags = [NSMutableArray array];
    for (NSString *part in [value componentsSeparatedByString:@","]) {
        [flags addObject:[NSNumber numberWithBool:([part intValue] != 0)]];
    }
    return flags;
}

- (BOOL)offersAccelProfile:(NSString *)profile
{
    NSArray *available = Flags([self libinputValue:@"Accel Profiles Available"]);
    for (NSUInteger i = 0; i < kProfileCount && i < [available count]; i++) {
        if ([kProfiles[i] isEqualToString:profile]) {
            /* Without the resolution a curve cannot be converted to device
               units, so Custom is not offered rather than applied wrongly. */
            if ([profile isEqualToString:@"custom"] && _unitsPerMM <= 0.0) {
                return NO;
            }
            return [[available objectAtIndex:i] boolValue];
        }
    }
    return NO;
}

- (NSString *)activeAccelProfile
{
    NSArray *enabled = Flags([self libinputValue:@"Accel Profile Enabled"]);
    for (NSUInteger i = 0; i < kProfileCount && i < [enabled count]; i++) {
        if ([[enabled objectAtIndex:i] boolValue]) {
            return kProfiles[i];
        }
    }
    return nil;
}

+ (NSArray *)slavePointersInXinputList:(NSString *)output
{
    /* xinput draws the device tree with Unicode glyphs, or with ~ and >
       where it does not; neither is part of a name. */
    NSCharacterSet *tree = [NSCharacterSet characterSetWithCharactersInString:
        @" \t~>⎡⎜⎣↳"];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSArray *fields = [line componentsSeparatedByString:@"\t"];
        if ([fields count] < 3
            || ![[fields objectAtIndex:1] hasPrefix:@"id="]
            || [[fields objectAtIndex:2] rangeOfString:@"slave  pointer"].location == NSNotFound) {
            continue;
        }
        NSString *name = [[fields objectAtIndex:0] stringByTrimmingCharactersInSet:tree];
        NSString *deviceID = [[fields objectAtIndex:1] substringFromIndex:3];
        if ([name length] == 0 || [deviceID length] == 0) {
            continue;
        }
        [result addObject:@{@"id" : deviceID, @"name" : name}];
    }
    return result;
}

+ (NSDictionary *)propertiesFromXinputListProps:(NSString *)output
{
    /* Each property line reads "<tab>Name (atom):<tab>value". */
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSRange sep = [line rangeOfString:@"):"];
        if (sep.location == NSNotFound) {
            continue;
        }
        NSString *head = [line substringToIndex:sep.location];
        NSRange open = [head rangeOfString:@" (" options:NSBackwardsSearch];
        if (open.location == NSNotFound) {
            continue;
        }
        NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
        NSString *name = [[head substringToIndex:open.location] stringByTrimmingCharactersInSet:ws];
        NSString *value = [[line substringFromIndex:NSMaxRange(sep)] stringByTrimmingCharactersInSet:ws];
        if ([name length] > 0 && [value length] > 0) {
            [result setObject:value forKey:name];
        }
    }
    return result;
}

+ (PointerDeviceKind)kindForName:(NSString *)name properties:(NSDictionary *)properties
{
    if ([properties objectForKey:@"libinput Accel Speed"] == nil) {
        return PointerDeviceKindNone;
    }
    if ([properties objectForKey:@"libinput Tapping Enabled"] != nil) {
        return PointerDeviceKindTouchpad;
    }
    for (NSString *stick in @[@"TrackPoint", @"Trackpoint", @"TPPS/2",
                              @"Pointing Stick", @"pointing stick"]) {
        if ([name rangeOfString:stick].location != NSNotFound) {
            return PointerDeviceKindTrackpoint;
        }
    }
    return PointerDeviceKindMouse;
}

@end
