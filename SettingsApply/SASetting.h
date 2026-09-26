/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* One persisted preference-pane setting that gershwin-apply-settings puts
 * back at login: where the pane stores it (a defaults domain and one or more
 * keys) and which SASettingsApplier method hands it to the pane's backend.
 * Several keys form one setting when the backend needs them together, such
 * as the two touchpad click mappings that end up in one libinput property. */
@interface SASetting : NSObject

@property (nonatomic, readonly, copy) NSString *domain;
/* All of these must be present, or the setting is left alone. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *keys;
/* Passed along when present, never required. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *optionalKeys;
/* The backend class and method that does the work, for the report. */
@property (nonatomic, readonly, copy) NSString *backend;
/* Name of an SASettingsApplier method taking the values dictionary and
 * returning BOOL. */
@property (nonatomic, readonly, copy) NSString *applierSelector;

+ (instancetype)settingWithDomain:(NSString *)domain
                             keys:(NSArray<NSString *> *)keys
                     optionalKeys:(NSArray<NSString *> *)optionalKeys
                          backend:(NSString *)backend
                  applierSelector:(NSString *)applierSelector;

@end

/* A setting whose keys the user's defaults hold, with the values found. */
@interface SAPlannedApply : NSObject

@property (nonatomic, readonly, strong) SASetting *setting;
@property (nonatomic, readonly, copy) NSDictionary *values;

+ (instancetype)plannedApplyWithSetting:(SASetting *)setting values:(NSDictionary *)values;

/* "Domain key=value key=value -> backend", keys in the setting's order. */
- (NSString *)reportLine;

@end
