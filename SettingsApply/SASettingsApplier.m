/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "SASettingsApplier.h"
#import "KeyboardBackend.h"
#import "MouseBackend.h"
#import "EnergyBackend.h"
#import "CPUGovernorBackend.h"
#import "ProfileApplier.h"

/* Values come from defaults files a user may have edited with the defaults
 * tool, where a boolean or a number can arrive as a string ("YES", "0.5");
 * the panes read them with -boolValue/-floatValue, so both forms are
 * accepted.  Anything else is refused rather than guessed at. */
static BOOL IsScalar(id value)
{
    return [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]];
}

static void Refuse(NSString *key, id value)
{
    NSLog(@"gershwin-apply-settings: refusing %@ = %@ (%@): not a value the pane writes",
          key, value, NSStringFromClass([value class]));
}

@implementation SASettingsApplier
{
    MouseBackend *_mouse;
}

- (BOOL)apply:(SAPlannedApply *)planned
{
    SEL sel = NSSelectorFromString(planned.setting.applierSelector);
    if (![self respondsToSelector:sel]) {
        NSLog(@"gershwin-apply-settings: no applier method %@", planned.setting.applierSelector);
        return NO;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:sel]];
    NSDictionary *values = planned.values;
    BOOL ok = NO;
    [inv setTarget:self];
    [inv setSelector:sel];
    [inv setArgument:&values atIndex:2];
    [inv invoke];
    [inv getReturnValue:&ok];
    return ok;
}

- (BOOL)scalar:(NSString *)key in:(NSDictionary *)values into:(id *)out
{
    id value = [values objectForKey:key];
    if (!IsScalar(value)) {
        Refuse(key, value);
        return NO;
    }
    *out = value;
    return YES;
}

- (BOOL)string:(NSString *)key in:(NSDictionary *)values into:(NSString **)out
{
    id value = [values objectForKey:key];
    if (value == nil) {
        *out = nil;
        return YES;
    }
    if (![value isKindOfClass:[NSString class]]) {
        Refuse(key, value);
        return NO;
    }
    *out = value;
    return YES;
}

#pragma mark - Keyboard

- (BOOL)applyKeyboardLayout:(NSDictionary *)values
{
    NSString *layout, *variant, *options;
    if (![self string:@"layout" in:values into:&layout]
        || ![self string:@"variant" in:values into:&variant]
        || ![self string:@"options" in:values into:&options]) {
        return NO;
    }
    NSString *error = nil;
    if (![KeyboardBackend applyLayout:layout variant:variant options:options
                            setxkbmap:[KeyboardBackend findSetxkbmap] error:&error]) {
        NSLog(@"gershwin-apply-settings: keyboard layout %@: %@", layout, error);
        return NO;
    }
    return YES;
}

- (BOOL)applyAppleISOKeySwap:(NSDictionary *)values
{
    id isApple;
    NSString *keyboardType;
    if (![self scalar:@"isApple" in:values into:&isApple]
        || ![self string:@"keyboardType" in:values into:&keyboardType]) {
        return NO;
    }
    /* Only an Apple ISO board needs the swap; for any other board the
       layout just loaded is already right and there is nothing to do. */
    if (![KeyboardBackend needsAppleISOKeySwapForKeyboardType:keyboardType isApple:[isApple boolValue]]) {
        return YES;
    }
    return [KeyboardBackend applyAppleISOKeySwap];
}

#pragma mark - Mouse

/* One device scan serves every mouse setting of this run. */
- (MouseBackend *)mouse
{
    if (_mouse == nil) {
        _mouse = [[MouseBackend alloc] init];
        [_mouse refresh];
    }
    return _mouse;
}

- (BOOL)applyNaturalScrolling:(NSDictionary *)values
{
    id v;
    return [self scalar:@"naturalScrolling" in:values into:&v]
        && [[self mouse] applyNaturalScrolling:[v boolValue]];
}

- (BOOL)applyLeftHanded:(NSDictionary *)values
{
    id v;
    return [self scalar:@"leftHanded" in:values into:&v]
        && [[self mouse] applyLeftHanded:[v boolValue]];
}

- (BOOL)applyMouseSpeed:(NSDictionary *)values
{
    id v;
    return [self scalar:@"mouseSpeed" in:values into:&v]
        && [[self mouse] applyMouseSpeed:[v floatValue]];
}

- (BOOL)applyTrackpadSpeed:(NSDictionary *)values
{
    id v;
    return [self scalar:@"trackpadSpeed" in:values into:&v]
        && [[self mouse] applyTrackpadSpeed:[v floatValue]];
}

- (BOOL)applyTrackpointSpeed:(NSDictionary *)values
{
    id v;
    return [self scalar:@"trackpointSpeed" in:values into:&v]
        && [[self mouse] applyTrackpointSpeed:[v floatValue]];
}

- (BOOL)applyTapToClick:(NSDictionary *)values
{
    id v;
    return [self scalar:@"tapToClick" in:values into:&v]
        && [[self mouse] applyTapToClick:[v boolValue]];
}

- (BOOL)applyTapButtonMapping:(NSDictionary *)values
{
    id two, three;
    return [self scalar:@"twoFingerRightClick" in:values into:&two]
        && [self scalar:@"threeFingerMiddleClick" in:values into:&three]
        && [[self mouse] applyTwoFingerRightClick:[two boolValue]
                           threeFingerMiddleClick:[three boolValue]];
}

- (BOOL)applyDisableWhileTyping:(NSDictionary *)values
{
    id v;
    return [self scalar:@"disableWhileTyping" in:values into:&v]
        && [[self mouse] applyDisableWhileTyping:[v boolValue]];
}

#pragma mark - Energy

- (BOOL)applyGovernor:(NSDictionary *)values
{
    NSString *governor;
    if (![self string:@"governor" in:values into:&governor]) {
        return NO;
    }
    /* Writing the governor needs sudo; skipping an unchanged one keeps a
       login that changes nothing from asking for privileges at all. */
    if ([governor isEqualToString:[CPUGovernorBackend currentGovernor]]) {
        return YES;
    }
    return [CPUGovernorBackend setGovernor:governor];
}

- (BOOL)applyBrightness:(NSDictionary *)values
{
    id v;
    return [self scalar:@"brightness" in:values into:&v]
        && [EnergyBackend setBrightnessPercent:[v intValue]];
}

- (BOOL)applyScreenBlank:(NSDictionary *)values
{
    id v;
    if (![self scalar:@"screenBlank" in:values into:&v]) {
        return NO;
    }
    NSArray *choices = [EnergyBackend screenBlankChoices];
    int index = [v intValue];
    if (index < 0 || index >= (int)[choices count]) {
        Refuse(@"screenBlank", v);
        return NO;
    }
    return [EnergyBackend setScreenBlankSeconds:[[choices objectAtIndex:index] intValue]];
}

- (BOOL)applyHddSleep:(NSDictionary *)values
{
    id v;
    if (![self scalar:@"hddSleep" in:values into:&v]) {
        return NO;
    }
    if ([EnergyBackend readHddSleep] == [v boolValue]) {
        return YES;
    }
    return [EnergyBackend setHddSleep:[v boolValue]];
}

- (BOOL)applyWakeNetwork:(NSDictionary *)values
{
    id v;
    if (![self scalar:@"wakeNetwork" in:values into:&v]) {
        return NO;
    }
    if ([EnergyBackend readWakeNetwork] == [v boolValue]) {
        return YES;
    }
    return [EnergyBackend setWakeNetwork:[v boolValue]];
}

#pragma mark - Color

- (BOOL)applyColorProfiles:(NSDictionary *)values
{
    id profiles = [values objectForKey:@"ColorActiveProfiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) {
        Refuse(@"ColorActiveProfiles", profiles);
        return NO;
    }
    BOOL ok = YES;
    for (id output in profiles) {
        id path = [profiles objectForKey:output];
        if (![output isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) {
            Refuse(@"ColorActiveProfiles", profiles);
            ok = NO;
            continue;
        }
        if (![ProfileApplier loadProfile:path forOutput:output]) {
            NSLog(@"gershwin-apply-settings: could not load profile %@ for %@", path, output);
            ok = NO;
        }
    }
    return ok;
}

@end
