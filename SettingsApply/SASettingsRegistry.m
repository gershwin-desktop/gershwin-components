/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "SASettingsRegistry.h"
#import "MousePreferences.h"

static NSString *const kKeyboardDomain = @"KeyboardPreferences";
static NSString *const kEnergyDomain = @"EnergyPreferences";
/* The Color pane keeps its profiles in the domain of the application that
 * hosts it rather than a domain of its own. */
static NSString *const kColorDomain = @"SystemPreferences";

static SASetting *S(NSString *domain, NSArray *keys, NSString *backend, NSString *selector)
{
    return [SASetting settingWithDomain:domain keys:keys optionalKeys:@[]
                                backend:backend applierSelector:selector];
}

/* The settings every pointer class has; the applier finds the class from
 * the key's prefix.  Trackpoints get no curve: libinput scales their motion
 * before any profile, so a curve in device units would mean nothing. */
static NSArray *MouseSettings(PointerDeviceKind kind)
{
    NSString *(^key)(NSString *) = ^(NSString *setting) {
        return [MousePreferences key:setting forKind:kind];
    };
    NSMutableArray *list = [NSMutableArray arrayWithObject:
        S(MousePreferencesDomain, @[key(MousePreferencesSpeed)],
          @"MouseBackend -applySpeed:toKind:", @"applyPointerSpeed:")];
    if (kind != PointerDeviceKindTrackpoint) {
        [list addObject:S(MousePreferencesDomain, [MousePreferences curveKeysForKind:kind],
                          @"MouseBackend -applyAccelProfile:curve:toKind:", @"applyPointerCurve:")];
    }
    [list addObjectsFromArray:@[
        S(MousePreferencesDomain, @[key(MousePreferencesNaturalScrolling)],
          @"MouseBackend -applyNaturalScrolling:toKind:", @"applyPointerNaturalScrolling:"),
        S(MousePreferencesDomain, @[key(MousePreferencesLeftHanded)],
          @"MouseBackend -applyLeftHanded:toKind:", @"applyPointerLeftHanded:"),
        S(MousePreferencesDomain, @[key(MousePreferencesScrollSpeed)],
          @"MouseBackend -applyScrollSpeed:toKind:", @"applyPointerScrollSpeed:"),
    ]];
    return list;
}

@implementation SASettingsRegistry

/* Not re-applied, on purpose:
 *  - EnergyPreferences preventSleep: a sleep inhibitor held by a running
 *    process; a tool that exits at once cannot hold it.
 *  - EnergyPreferences powerFail: arms a one-shot RTC alarm a day ahead;
 *    re-arming it at every login would wake the machine a day after each
 *    login, which is not what the checkbox promises.
 *  - Display: resolution and layout go to /etc/X11/xorg.conf and the scale
 *    factor to NSGlobalDomain, both read again by the X server and every
 *    app on their own.
 *  - GlobalShortcuts and Menu: read by Menu itself at every start.
 *  - Sound: the chosen devices go to ~/.asoundrc and the alert settings to
 *    a plist the Sound backend reads whenever it starts; the mixer level is
 *    kept by the OS (alsactl, mixer rc scripts), not by the pane.
 *  - Network, Bluetooth, Sharing, Printers, BootEnvironments, StartupDisk:
 *    stored in system configuration by the services themselves. */
+ (NSArray<SASetting *> *)settings
{
    static NSArray *settings;
    if (settings == nil) {
        NSMutableArray *list = [NSMutableArray array];
        [list addObjectsFromArray:@[
            [SASetting settingWithDomain:kKeyboardDomain
                                    keys:@[@"layout"]
                            optionalKeys:@[@"variant", @"options"]
                                 backend:@"KeyboardBackend +applyLayout:variant:options:setxkbmap:error:"
                         applierSelector:@"applyKeyboardLayout:"],
            S(kKeyboardDomain, @[@"isApple", @"keyboardType"],
              @"KeyboardBackend +applyAppleISOKeySwap", @"applyAppleISOKeySwap:"),

        ]];
        /* Per device class, speed before the curve: the System and Flat
           profiles scale with the speed, and a custom curve replaces it. */
        [list addObjectsFromArray:MouseSettings(PointerDeviceKindMouse)];
        [list addObjectsFromArray:MouseSettings(PointerDeviceKindTouchpad)];
        [list addObjectsFromArray:@[
            S(MousePreferencesDomain, @[@"tapToClick"],
              @"MouseBackend -applyTapToClick:", @"applyTapToClick:"),
            S(MousePreferencesDomain, @[@"twoFingerRightClick", @"threeFingerMiddleClick"],
              @"MouseBackend -applyTwoFingerRightClick:threeFingerMiddleClick:", @"applyTapButtonMapping:"),
            S(MousePreferencesDomain, @[@"disableWhileTyping"],
              @"MouseBackend -applyDisableWhileTyping:", @"applyDisableWhileTyping:"),
        ]];
        [list addObjectsFromArray:MouseSettings(PointerDeviceKindTrackpoint)];
        [list addObjectsFromArray:@[
            S(kEnergyDomain, @[@"governor"],
              @"CPUGovernorBackend +setGovernor:", @"applyGovernor:"),
            S(kEnergyDomain, @[@"brightness"],
              @"EnergyBackend +setBrightnessPercent:", @"applyBrightness:"),
            S(kEnergyDomain, @[@"screenBlank"],
              @"EnergyBackend +setScreenBlankSeconds:", @"applyScreenBlank:"),
            S(kEnergyDomain, @[@"hddSleep"],
              @"EnergyBackend +setHddSleep:", @"applyHddSleep:"),
            S(kEnergyDomain, @[@"wakeNetwork"],
              @"EnergyBackend +setWakeNetwork:", @"applyWakeNetwork:"),

            S(kColorDomain, @[@"ColorActiveProfiles"],
              @"ProfileApplier +loadProfile:forOutput:", @"applyColorProfiles:"),
        ]];
        settings = [list copy];
    }
    return settings;
}

+ (NSArray<NSString *> *)domains
{
    NSMutableArray *domains = [NSMutableArray array];
    for (SASetting *s in [self settings]) {
        if (![domains containsObject:s.domain]) {
            [domains addObject:s.domain];
        }
    }
    return domains;
}

+ (NSDictionary<NSString *, NSDictionary *> *)domainsByMigrating:(NSDictionary<NSString *, NSDictionary *> *)domains
{
    NSDictionary *mouse = [domains objectForKey:MousePreferencesDomain];
    if (mouse == nil) {
        return domains;
    }
    NSMutableDictionary *out = [domains mutableCopy];
    [out setObject:[MousePreferences migratedDomain:mouse] forKey:MousePreferencesDomain];
    return out;
}

+ (NSArray<SAPlannedApply *> *)planForSettings:(NSArray<SASetting *> *)settings
                                       domains:(NSDictionary<NSString *, NSDictionary *> *)domains
{
    NSMutableArray *plan = [NSMutableArray array];
    for (SASetting *s in settings) {
        NSDictionary *domain = [domains objectForKey:s.domain];
        if (domain == nil) {
            continue;
        }
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        BOOL complete = YES;
        for (NSString *key in s.keys) {
            id value = [domain objectForKey:key];
            if (value == nil) {
                complete = NO;
                break;
            }
            [values setObject:value forKey:key];
        }
        if (!complete) {
            continue;
        }
        for (NSString *key in s.optionalKeys) {
            id value = [domain objectForKey:key];
            if (value != nil) {
                [values setObject:value forKey:key];
            }
        }
        [plan addObject:[SAPlannedApply plannedApplyWithSetting:s values:values]];
    }
    return plan;
}

@end
