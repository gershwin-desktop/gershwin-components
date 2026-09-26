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

/* The pointer settings take one key of any device class (mouseSpeed,
 * trackpadSpeed, ...); the class comes from the key's prefix. */
- (BOOL)applyPointerSpeed:(NSDictionary *)values;
- (BOOL)applyPointerNaturalScrolling:(NSDictionary *)values;
- (BOOL)applyPointerLeftHanded:(NSDictionary *)values;
- (BOOL)applyPointerScrollSpeed:(NSDictionary *)values;
/* The five curve keys of one class. */
- (BOOL)applyPointerCurve:(NSDictionary *)values;
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
