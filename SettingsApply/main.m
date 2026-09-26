/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* gershwin-apply-settings: puts the settings saved by the preference panes
 * back into effect.  The panes apply a change live and save it to the
 * user's defaults, but keyboard layouts, libinput properties, DPMS, the
 * backlight, the CPU governor and display profiles all reset when the
 * machine or the X server restarts; Gershwin.sh runs this once per login.
 *
 *   gershwin-apply-settings            apply every saved setting
 *   gershwin-apply-settings --dry-run  only list what would be applied
 *
 * A setting the user never saved is not touched.  Exits 1 if any backend
 * failed, so the session log shows which one. */

#import <Foundation/Foundation.h>
#import "SASettingsRegistry.h"
#import "SASettingsApplier.h"
#include <stdio.h>

static void Print(NSString *line)
{
    fprintf(stdout, "gershwin-apply-settings: %s\n", [line UTF8String]);
    fflush(stdout);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        BOOL dryRun = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--dry-run") == 0) {
                dryRun = YES;
            } else {
                fprintf(stderr, "usage: gershwin-apply-settings [--dry-run]\n");
                return 2;
            }
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *domains = [NSMutableDictionary dictionary];
        for (NSString *name in [SASettingsRegistry domains]) {
            NSDictionary *domain = [defaults persistentDomainForName:name];
            if (domain != nil) {
                [domains setObject:domain forKey:name];
            }
        }

        NSArray *settings = [SASettingsRegistry settings];
        NSArray *plan = [SASettingsRegistry planForSettings:settings domains:domains];

        if (dryRun) {
            NSMutableSet *planned = [NSMutableSet set];
            for (SAPlannedApply *p in plan) {
                [planned addObject:p.setting];
                Print([@"would apply " stringByAppendingString:[p reportLine]]);
            }
            for (SASetting *s in settings) {
                if (![planned containsObject:s]) {
                    Print([NSString stringWithFormat:@"not set, left alone: %@ %@",
                                    s.domain, [s.keys componentsJoinedByString:@"+"]]);
                }
            }
            return 0;
        }

        SASettingsApplier *applier = [[SASettingsApplier alloc] init];
        int failures = 0;
        for (SAPlannedApply *p in plan) {
            BOOL ok = [applier apply:p];
            Print([NSString stringWithFormat:@"%@: %@", [p reportLine], ok ? @"ok" : @"FAILED"]);
            if (!ok) {
                failures++;
            }
        }
        return failures > 0 ? 1 : 0;
    }
}
