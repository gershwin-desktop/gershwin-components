/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The xinput side of the Mouse preference pane, shared with
 * gershwin-apply-settings so the login-time re-apply drives exactly the
 * libinput properties the pane drives live.  Built as libMouseBackend
 * (Libraries/MouseBackend) under ARC; everything handed out is autoreleased
 * from the caller's point of view.
 *
 * The apply methods return NO when xinput is missing or any xinput call for
 * a detected device failed; a device class that is not present is skipped
 * and does not count as a failure. */
@interface MouseBackend : NSObject

@property (nonatomic, readonly, copy) NSString *xinputPath;
@property (nonatomic, readonly, copy) NSString *touchpadName;
@property (nonatomic, readonly, copy) NSString *mouseName;
@property (nonatomic, readonly, copy) NSString *trackpointName;

/* Looks xinput up again if it was not found yet, then re-reads the device
 * list, because pointing devices come and go (USB, Bluetooth). */
- (void)refresh;

- (NSDictionary *)propertiesForDevice:(NSString *)device;

/* Takes the name without the "libinput " prefix, e.g. "Accel Speed".  The
 * match is exact because a fragment also matches the driver's read-only
 * "<name> Default" twin and would report the default, not the current
 * value. */
+ (NSString *)propertyValue:(NSDictionary *)props name:(NSString *)name;

/* libinput feeds the custom acceleration profile raw touchpad units, and X
 * does not expose the resolution needed to convert a curve to them; only the
 * evdev node named in the touchpad's "Device Node" property does.  Returns 0
 * where it cannot be read. */
+ (double)unitsPerMMForProperties:(NSDictionary *)props;

- (BOOL)applyNaturalScrolling:(BOOL)enabled;
- (BOOL)applyLeftHanded:(BOOL)enabled;
- (BOOL)applyMouseSpeed:(float)speed;
- (BOOL)applyTrackpadSpeed:(float)speed;
- (BOOL)applyTrackpointSpeed:(float)speed;
- (BOOL)applyTapToClick:(BOOL)enabled;
- (BOOL)applyTwoFingerRightClick:(BOOL)twoFinger threeFingerMiddleClick:(BOOL)threeFinger;
- (BOOL)applyDisableWhileTyping:(BOOL)enabled;

/* profile is one of the curveProfile values the pane stores: "system"
 * (libinput's adaptive profile), "flat" or "custom".  points and step only
 * matter for "custom"; they are in the touchpad's own units (see
 * +unitsPerMMForProperties:). */
- (BOOL)applyTrackpadAccelProfile:(NSString *)profile
                     customPoints:(NSArray *)points
                             step:(double)step;

@end
