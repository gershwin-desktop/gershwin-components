/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "PointerDevice.h"
#import "AccelerationCurve.h"

/* The MousePreferences defaults domain, shared by the Mouse pane (writes)
 * and gershwin-apply-settings (re-applies at login).  Per-class settings
 * are stored as <prefix><Setting>, e.g. mouseSpeed, trackpadCurveProfile;
 * the touchpad-only tap settings keep their plain names (tapToClick,
 * twoFingerRightClick, threeFingerMiddleClick, disableWhileTyping). */

extern NSString *const MousePreferencesDomain;

extern NSString *const MousePreferencesSpeed;             /* float -1..1 */
extern NSString *const MousePreferencesNaturalScrolling;  /* BOOL */
extern NSString *const MousePreferencesLeftHanded;        /* BOOL */
extern NSString *const MousePreferencesScrollSpeed;       /* double, see MouseBackend */
extern NSString *const MousePreferencesCurveProfile;      /* system, flat, custom */
extern NSString *const MousePreferencesCurvePrecision;    /* AccelerationCurve fields */
extern NSString *const MousePreferencesCurveStart;
extern NSString *const MousePreferencesCurveEnd;
extern NSString *const MousePreferencesCurveFast;

@interface MousePreferences : NSObject

/* "mouse", "trackpad" or "trackpoint". */
+ (NSString *)keyPrefixForKind:(PointerDeviceKind)kind;
+ (NSString *)key:(NSString *)setting forKind:(PointerDeviceKind)kind;

/* The five curve keys of a class, in the order they are applied. */
+ (NSArray *)curveKeysForKind:(PointerDeviceKind)kind;

/* Earlier versions stored naturalScrolling and leftHanded once for all
 * devices and the trackpad curve as curveProfile/curve*.  Returns the domain
 * with those moved to the per-class keys; a per-class key that is already
 * set wins. */
+ (NSDictionary *)migratedDomain:(NSDictionary *)domain;

/* The stored curve of a class, or NO when any of its four parameters is
 * missing or not a number. */
+ (BOOL)curve:(AccelerationCurve *)curve forKind:(PointerDeviceKind)kind
     inDomain:(NSDictionary *)domain;

/* The user's domain, migrated. */
+ (NSDictionary *)currentDomain;
/* Writes one key into the user's domain (migrating it on the way) and
 * leaves every other key as it is. */
+ (void)setObject:(id)value forKey:(NSString *)key;

@end
