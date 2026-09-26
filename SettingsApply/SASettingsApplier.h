/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "SASetting.h"

/* Hands each planned setting to the backend the pane itself uses.  Every
 * apply method takes the values dictionary of an SAPlannedApply and returns
 * whether the backend succeeded; a value of the wrong type is a failure,
 * never replaced by a default. */
@interface SASettingsApplier : NSObject

- (BOOL)apply:(SAPlannedApply *)planned;

- (BOOL)applyKeyboardLayout:(NSDictionary *)values;
- (BOOL)applyAppleISOKeySwap:(NSDictionary *)values;

- (BOOL)applyNaturalScrolling:(NSDictionary *)values;
- (BOOL)applyLeftHanded:(NSDictionary *)values;
- (BOOL)applyMouseSpeed:(NSDictionary *)values;
- (BOOL)applyTrackpadSpeed:(NSDictionary *)values;
- (BOOL)applyTrackpointSpeed:(NSDictionary *)values;
- (BOOL)applyTapToClick:(NSDictionary *)values;
- (BOOL)applyTapButtonMapping:(NSDictionary *)values;
- (BOOL)applyDisableWhileTyping:(NSDictionary *)values;

- (BOOL)applyGovernor:(NSDictionary *)values;
- (BOOL)applyBrightness:(NSDictionary *)values;
- (BOOL)applyScreenBlank:(NSDictionary *)values;
- (BOOL)applyHddSleep:(NSDictionary *)values;
- (BOOL)applyWakeNetwork:(NSDictionary *)values;

- (BOOL)applyColorProfiles:(NSDictionary *)values;

@end
