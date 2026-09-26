/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "SASetting.h"

@implementation SASetting

+ (instancetype)settingWithDomain:(NSString *)domain
                             keys:(NSArray<NSString *> *)keys
                     optionalKeys:(NSArray<NSString *> *)optionalKeys
                          backend:(NSString *)backend
                  applierSelector:(NSString *)applierSelector
{
    SASetting *s = [[self alloc] init];
    s->_domain = [domain copy];
    s->_keys = [keys copy];
    s->_optionalKeys = [optionalKeys copy];
    s->_backend = [backend copy];
    s->_applierSelector = [applierSelector copy];
    return s;
}

@end

@implementation SAPlannedApply

+ (instancetype)plannedApplyWithSetting:(SASetting *)setting values:(NSDictionary *)values
{
    SAPlannedApply *p = [[self alloc] init];
    p->_setting = setting;
    p->_values = [values copy];
    return p;
}

- (NSString *)reportLine
{
    return @"";
}

@end
