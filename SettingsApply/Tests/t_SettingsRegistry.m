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
            @"MousePreferences/mouseSpeed" : @"applyPointerSpeed:",
            @"MousePreferences/mouseCurveProfile+mouseCurvePrecision+mouseCurveStart+mouseCurveEnd+mouseCurveFast" : @"applyPointerCurve:",
            @"MousePreferences/mouseNaturalScrolling" : @"applyPointerNaturalScrolling:",
            @"MousePreferences/mouseLeftHanded" : @"applyPointerLeftHanded:",
            @"MousePreferences/mouseScrollSpeed" : @"applyPointerScrollSpeed:",
            @"MousePreferences/trackpadSpeed" : @"applyPointerSpeed:",
            @"MousePreferences/trackpadCurveProfile+trackpadCurvePrecision+trackpadCurveStart+trackpadCurveEnd+trackpadCurveFast" : @"applyPointerCurve:",
            @"MousePreferences/trackpadNaturalScrolling" : @"applyPointerNaturalScrolling:",
            @"MousePreferences/trackpadLeftHanded" : @"applyPointerLeftHanded:",
            @"MousePreferences/trackpadScrollSpeed" : @"applyPointerScrollSpeed:",
            @"MousePreferences/trackpointSpeed" : @"applyPointerSpeed:",
            @"MousePreferences/trackpointNaturalScrolling" : @"applyPointerNaturalScrolling:",
            @"MousePreferences/trackpointLeftHanded" : @"applyPointerLeftHanded:",
            @"MousePreferences/trackpointScrollSpeed" : @"applyPointerScrollSpeed:",
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
            kMouseDomain : @{@"trackpadNaturalScrolling" : @YES},
        }];
        PASS([plan count] == 1, "only the one key the user has is applied");
        SAPlannedApply *p = [plan firstObject];
        NSDictionary *wantValues = @{@"trackpadNaturalScrolling" : @YES};
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

    START_SET("acceleration curves of both classes")
    {
        NSDictionary *mouse = @{@"mouseCurveProfile" : @"custom", @"mouseCurvePrecision" : @1.0,
                                @"mouseCurveStart" : @0.1, @"mouseCurveEnd" : @0.35,
                                @"mouseCurveFast" : @2.0};
        NSDictionary *trackpad = @{@"trackpadCurveProfile" : @"flat", @"trackpadCurvePrecision" : @0.3,
                                   @"trackpadCurveStart" : @0.2, @"trackpadCurveEnd" : @0.7,
                                   @"trackpadCurveFast" : @1.6};
        NSMutableDictionary *both = [NSMutableDictionary dictionaryWithDictionary:mouse];
        [both addEntriesFromDictionary:trackpad];
        [both setObject:@0.5 forKey:@"mouseSpeed"];
        NSArray *plan = [SASettingsRegistry planForSettings:settings domains:@{kMouseDomain : both}];
        NSArray *ids = PlannedIDs(plan);
        NSArray *want = @[
            @"MousePreferences/mouseSpeed",
            @"MousePreferences/mouseCurveProfile+mouseCurvePrecision+mouseCurveStart+mouseCurveEnd+mouseCurveFast",
            @"MousePreferences/trackpadCurveProfile+trackpadCurvePrecision+trackpadCurveStart+trackpadCurveEnd+trackpadCurveFast",
        ];
        PASS_EQUAL(ids, want, "both curves are re-applied, each after its class's speed");
        PASS_EQUAL([[plan objectAtIndex:1] values], mouse, "the mouse curve gets all five keys");
        PASS_EQUAL([[plan lastObject] reportLine],
                   @"MousePreferences trackpadCurveProfile=flat trackpadCurvePrecision=0.3 trackpadCurveStart=0.2 trackpadCurveEnd=0.7 trackpadCurveFast=1.6 -> MouseBackend -applyAccelProfile:curve:toKind:",
                   "the report names the curve and the backend method");

        NSMutableDictionary *partial = [NSMutableDictionary dictionaryWithDictionary:mouse];
        [partial removeObjectForKey:@"mouseCurveFast"];
        plan = [SASettingsRegistry planForSettings:settings domains:@{kMouseDomain : partial}];
        PASS([plan count] == 0, "a curve with a key missing is left alone");

        SASettingsApplier *applier = [[SASettingsApplier new] autorelease];
        NSMutableDictionary *bogus = [NSMutableDictionary dictionaryWithDictionary:mouse];
        [bogus setObject:@[@1] forKey:@"mouseCurveStart"];
        SAPlannedApply *p = [SAPlannedApply plannedApplyWithSetting:[[SASettingsRegistry planForSettings:settings
            domains:@{kMouseDomain : mouse}] firstObject].setting values:bogus];
        PASS(![applier apply:p], "a curve parameter that is no number is refused before any backend call");
    }
    END_SET("acceleration curves of both classes")

    START_SET("older shared keys still re-apply")
    {
        NSDictionary *domains = [SASettingsRegistry domainsByMigrating:@{
            kMouseDomain : @{@"naturalScrolling" : @YES, @"curveProfile" : @"system",
                             @"curvePrecision" : @0.3, @"curveStart" : @0.2, @"curveEnd" : @0.7,
                             @"curveFast" : @1.6},
        }];
        NSArray *ids = PlannedIDs([SASettingsRegistry planForSettings:settings domains:domains]);
        NSArray *want = @[
            @"MousePreferences/mouseNaturalScrolling",
            @"MousePreferences/trackpadCurveProfile+trackpadCurvePrecision+trackpadCurveStart+trackpadCurveEnd+trackpadCurveFast",
            @"MousePreferences/trackpadNaturalScrolling",
            @"MousePreferences/trackpointNaturalScrolling",
        ];
        PASS_EQUAL(ids, want, "the shared scroll direction reaches every class, the old curve the trackpad");
        NSDictionary *other = @{@"EnergyPreferences" : @{@"governor" : @"powersave"}};
        PASS_EQUAL([SASettingsRegistry domainsByMigrating:other], other, "other domains pass unchanged");
    }
    END_SET("older shared keys still re-apply")

    START_SET("dry-run report")
    {
        NSArray *plan = [SASettingsRegistry planForSettings:settings domains:@{
            kMouseDomain : @{@"mouseNaturalScrolling" : @YES},
            @"EnergyPreferences" : @{@"governor" : @"powersave"},
        }];
        NSArray *lines = @[[[plan objectAtIndex:0] reportLine], [[plan objectAtIndex:1] reportLine]];
        NSArray *want = @[
            @"MousePreferences mouseNaturalScrolling=1 -> MouseBackend -applyNaturalScrolling:toKind:",
            @"EnergyPreferences governor=powersave -> CPUGovernorBackend +setGovernor:",
        ];
        PASS_EQUAL(lines, want, "one line per setting: domain, values, backend method");
    }
    END_SET("dry-run report")

    [arp release];
    return 0;
}
