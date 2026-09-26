/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "SASettingsRegistry.h"

static NSString *const kKeyboardDomain = @"KeyboardPreferences";
static NSString *const kMouseDomain = @"MousePreferences";
static NSString *const kEnergyDomain = @"EnergyPreferences";
/* The Color pane keeps its profiles in the domain of the application that
 * hosts it rather than a domain of its own. */
static NSString *const kColorDomain = @"SystemPreferences";

static SASetting *S(NSString *domain, NSArray *keys, NSString *backend, NSString *selector)
{
    return [SASetting settingWithDomain:domain keys:keys optionalKeys:@[]
                                backend:backend applierSelector:selector];
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
        settings = @[
            [SASetting settingWithDomain:kKeyboardDomain
                                    keys:@[@"layout"]
                            optionalKeys:@[@"variant", @"options"]
                                 backend:@"KeyboardBackend +applyLayout:variant:options:setxkbmap:error:"
                         applierSelector:@"applyKeyboardLayout:"],
            S(kKeyboardDomain, @[@"isApple", @"keyboardType"],
              @"KeyboardBackend +applyAppleISOKeySwap", @"applyAppleISOKeySwap:"),

            S(kMouseDomain, @[@"naturalScrolling"],
              @"MouseBackend -applyNaturalScrolling:", @"applyNaturalScrolling:"),
            S(kMouseDomain, @[@"leftHanded"],
              @"MouseBackend -applyLeftHanded:", @"applyLeftHanded:"),
            S(kMouseDomain, @[@"mouseSpeed"],
              @"MouseBackend -applyMouseSpeed:", @"applyMouseSpeed:"),
            S(kMouseDomain, @[@"trackpadSpeed"],
              @"MouseBackend -applyTrackpadSpeed:", @"applyTrackpadSpeed:"),
            S(kMouseDomain, @[@"trackpointSpeed"],
              @"MouseBackend -applyTrackpointSpeed:", @"applyTrackpointSpeed:"),
            S(kMouseDomain, @[@"tapToClick"],
              @"MouseBackend -applyTapToClick:", @"applyTapToClick:"),
            S(kMouseDomain, @[@"twoFingerRightClick", @"threeFingerMiddleClick"],
              @"MouseBackend -applyTwoFingerRightClick:threeFingerMiddleClick:", @"applyTapButtonMapping:"),
            S(kMouseDomain, @[@"disableWhileTyping"],
              @"MouseBackend -applyDisableWhileTyping:", @"applyDisableWhileTyping:"),

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
        ];
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
