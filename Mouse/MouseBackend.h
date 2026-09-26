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

/* xinput list-props names carry the driver prefix and the property id, so
 * callers match on a fragment such as "Accel Speed". */
+ (NSString *)propertyValue:(NSDictionary *)props name:(NSString *)name;

- (BOOL)applyNaturalScrolling:(BOOL)enabled;
- (BOOL)applyLeftHanded:(BOOL)enabled;
/* The mouse slider drives the touchpad too, as the pane always has. */
- (BOOL)applyMouseSpeed:(float)speed;
- (BOOL)applyTrackpadSpeed:(float)speed;
- (BOOL)applyTrackpointSpeed:(float)speed;
- (BOOL)applyTapToClick:(BOOL)enabled;
- (BOOL)applyTwoFingerRightClick:(BOOL)twoFinger threeFingerMiddleClick:(BOOL)threeFinger;
- (BOOL)applyDisableWhileTyping:(BOOL)enabled;

@end
