/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The decision half of gershwin-apply-settings: which pane setting maps to
 * which backend method, and which of them a given set of defaults leads to.
 * Headless; no backend is called. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SASettingsRegistry.h"
#import "SASettingsApplier.h"

static NSString *const kMouseDomain = @"MousePreferences";

static NSString *SettingID(SASetting *s)
{
    return [NSString stringWithFormat:@"%@/%@", s.domain,
                     [s.keys componentsJoinedByString:@"+"]];
}

static NSArray *PlannedIDs(NSArray *plan)
{
    NSMutableArray *ids = [NSMutableArray array];
    for (SAPlannedApply *p in plan) {
        [ids addObject:SettingID(p.setting)];
    }
    return ids;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSArray *settings = [SASettingsRegistry settings];

    START_SET("registry maps every persisted pane key to its backend")
    {
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (SASetting *s in settings) {
            [map setObject:s.applierSelector forKey:SettingID(s)];
        }
        NSDictionary *want = @{
            @"KeyboardPreferences/layout" : @"applyKeyboardLayout:",
            @"KeyboardPreferences/isApple+keyboardType" : @"applyAppleISOKeySwap:",
            @"MousePreferences/naturalScrolling" : @"applyNaturalScrolling:",
            @"MousePreferences/leftHanded" : @"applyLeftHanded:",
            @"MousePreferences/mouseSpeed" : @"applyMouseSpeed:",
            @"MousePreferences/trackpadSpeed" : @"applyTrackpadSpeed:",
            @"MousePreferences/trackpointSpeed" : @"applyTrackpointSpeed:",
            @"MousePreferences/tapToClick" : @"applyTapToClick:",
            @"MousePreferences/twoFingerRightClick+threeFingerMiddleClick" : @"applyTapButtonMapping:",
            @"MousePreferences/disableWhileTyping" : @"applyDisableWhileTyping:",
            @"EnergyPreferences/governor" : @"applyGovernor:",
            @"EnergyPreferences/brightness" : @"applyBrightness:",
            @"EnergyPreferences/screenBlank" : @"applyScreenBlank:",
            @"EnergyPreferences/hddSleep" : @"applyHddSleep:",
            @"EnergyPreferences/wakeNetwork" : @"applyWakeNetwork:",
            @"SystemPreferences/ColorActiveProfiles" : @"applyColorProfiles:",
        };
        PASS_EQUAL(map, want, "each setting is applied by the method named for it");
        PASS([map count] == [settings count], "no setting is listed twice");

        BOOL allImplemented = [settings count] > 0;
        for (SASetting *s in settings) {
            if (![SASettingsApplier instancesRespondToSelector:NSSelectorFromString(s.applierSelector)]) {
                allImplemented = NO;
            }
        }
        PASS(allImplemented, "the applier implements every selector the registry names");

        NSArray *wantDomains = @[@"KeyboardPreferences", @"MousePreferences",
                                 @"EnergyPreferences", @"SystemPreferences"];
        PASS_EQUAL([SASettingsRegistry domains], wantDomains, "each domain is read once, in apply order");
    }
    END_SET("registry maps every persisted pane key to its backend")

    START_SET("order follows the panes")
    {
        NSArray *ids = PlannedIDs([SASettingsRegistry planForSettings:settings domains:@{
            @"KeyboardPreferences" : @{@"layout" : @"de", @"isApple" : @YES, @"keyboardType" : @"ISO"},
            kMouseDomain : @{@"trackpadSpeed" : @0.2, @"mouseSpeed" : @0.5},
        }]);
        NSArray *want = @[@"KeyboardPreferences/layout", @"KeyboardPreferences/isApple+keyboardType",
                          @"MousePreferences/mouseSpeed", @"MousePreferences/trackpadSpeed"];
        PASS_EQUAL(ids, want, "layout before key swap, mouse speed before the trackpad speed that overrides it");
    }
    END_SET("order follows the panes")

    START_SET("absent keys leave the system alone")
    {
        NSArray *plan = [SASettingsRegistry planForSettings:settings domains:@{}];
        PASS([plan count] == 0, "no defaults at all: nothing is applied");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            kMouseDomain : @{@"naturalScrolling" : @YES},
        }];
        PASS([plan count] == 1, "only the one key the user has is applied");
        SAPlannedApply *p = [plan firstObject];
        NSDictionary *wantValues = @{@"naturalScrolling" : @YES};
        PASS_EQUAL(p.values, wantValues, "its value is passed on unchanged");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            kMouseDomain : @{@"twoFingerRightClick" : @YES},
        }];
        PASS([plan count] == 0, "a setting made of two keys is skipped when one of them is missing");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            kMouseDomain : @{@"twoFingerRightClick" : @YES, @"threeFingerMiddleClick" : @NO},
        }];
        NSDictionary *wantBoth = @{@"twoFingerRightClick" : @YES, @"threeFingerMiddleClick" : @NO};
        PASS([plan count] == 1 && [[[plan firstObject] values] isEqual:wantBoth],
             "both click mappings present: applied together");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            @"KeyboardPreferences" : @{@"layout" : @"de"},
        }];
        NSDictionary *wantLayout = @{@"layout" : @"de"};
        PASS([plan count] == 1 && [[[plan firstObject] values] isEqual:wantLayout],
             "a missing variant is left out, not filled in");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            @"KeyboardPreferences" : @{@"layout" : @"de", @"variant" : @"nodeadkeys", @"options" : @""},
        }];
        NSDictionary *wantFull = @{@"layout" : @"de", @"variant" : @"nodeadkeys", @"options" : @""};
        PASS([[[plan firstObject] values] isEqual:wantFull], "optional variant and options are passed on when present");

        plan = [SASettingsRegistry planForSettings:settings domains:@{
            @"EnergyPreferences" : @{@"preventSleep" : @YES, @"powerFail" : @YES},
            @"SystemPreferences" : @{@"NSWindow Frame SystemPreferences" : @"0 0 10 10"},
        }];
        PASS([plan count] == 0, "keys that are not re-applied settings are ignored");
    }
    END_SET("absent keys leave the system alone")

    START_SET("dry-run report")
    {
        NSArray *plan = [SASettingsRegistry planForSettings:settings domains:@{
            kMouseDomain : @{@"naturalScrolling" : @YES},
            @"EnergyPreferences" : @{@"governor" : @"powersave"},
        }];
        NSArray *lines = @[[[plan objectAtIndex:0] reportLine], [[plan objectAtIndex:1] reportLine]];
        NSArray *want = @[
            @"MousePreferences naturalScrolling=1 -> MouseBackend -applyNaturalScrolling:",
            @"EnergyPreferences governor=powersave -> CPUGovernorBackend +setGovernor:",
        ];
        PASS_EQUAL(lines, want, "one line per setting: domain, values, backend method");
    }
    END_SET("dry-run report")

    [arp release];
    return 0;
}
