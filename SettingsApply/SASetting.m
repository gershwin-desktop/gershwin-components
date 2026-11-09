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

/* Values are shown on one line so each setting stays one line of the log,
 * even a dictionary of display profiles. */
static NSString *OneLine(id value)
{
    NSString *d = [value description];
    NSArray *parts = [d componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *trimmed = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t length] > 0) {
            [trimmed addObject:t];
        }
    }
    return [trimmed componentsJoinedByString:@" "];
}

- (NSString *)reportLine
{
    NSMutableString *line = [NSMutableString stringWithString:self.setting.domain];
    NSArray *ordered = [self.setting.keys arrayByAddingObjectsFromArray:self.setting.optionalKeys];
    for (NSString *key in ordered) {
        id value = [self.values objectForKey:key];
        if (value != nil) {
            [line appendFormat:@" %@=%@", key, OneLine(value)];
        }
    }
    [line appendFormat:@" -> %@", self.setting.backend];
    return line;
}

@end
