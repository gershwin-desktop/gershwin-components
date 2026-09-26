/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "SASettingsRegistry.h"

@implementation SASettingsRegistry

+ (NSArray<SASetting *> *)settings
{
    return @[];
}

+ (NSArray<NSString *> *)domains
{
    return @[];
}

+ (NSArray<SAPlannedApply *> *)planForSettings:(NSArray<SASetting *> *)settings
                                       domains:(NSDictionary<NSString *, NSDictionary *> *)domains
{
    return @[];
}

@end
