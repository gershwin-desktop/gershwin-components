/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "PointerDevice.h"
#import "AccelerationCurve.h"

/* The xinput side of the Mouse preference pane, shared with
 * gershwin-apply-settings so the login-time re-apply drives exactly the
 * libinput properties the pane drives live.  Built as libMouseBackend
 * (Libraries/MouseBackend) under ARC; everything handed out is autoreleased
 * from the caller's point of view.
 *
 * Settings are made per device class and go to every device of that class,
 * because they are stored per class and re-applied per class at login.
 * The apply methods return NO when xinput is missing or any xinput call for
 * a detected device failed; a class with no device present is skipped and
 * does not count as a failure. */
@interface MouseBackend : NSObject

@property (nonatomic, readonly, copy) NSString *xinputPath;
/* Every classified pointer found by the last -refresh. */
@property (nonatomic, readonly, copy) NSArray *devices;

/* Uses the xinput found on PATH (then the usual install locations). */
- (instancetype)init;
/* path nil means there is no xinput. */
- (instancetype)initWithXinputPath:(NSString *)path;

/* Re-reads and re-classifies the device list, because pointing devices
 * come and go (USB, Bluetooth): -useDevices: with -scanDevices. */
- (void)refresh;

/* Lists and classifies the pointers.  It runs one xinput call per slave
 * pointer and reads the touchpads' evdev nodes, and changes nothing, so the
 * pane runs it on another thread while the backend keeps applying to the
 * devices it has. */
- (NSArray *)scanDevices;
- (void)useDevices:(NSArray *)devices;

- (NSArray *)devicesOfKind:(PointerDeviceKind)kind;

- (BOOL)applySpeed:(float)speed toKind:(PointerDeviceKind)kind;
- (BOOL)applyNaturalScrolling:(BOOL)enabled toKind:(PointerDeviceKind)kind;
- (BOOL)applyLeftHanded:(BOOL)enabled toKind:(PointerDeviceKind)kind;
/* Only devices with a scroll distance (two-finger and button scrolling)
 * take it; a wheel scrolls in detents libinput does not scale. */
- (BOOL)applyScrollSpeed:(double)speed toKind:(PointerDeviceKind)kind;
/* profile is "system" (libinput's adaptive profile), "flat" or "custom";
 * the curve only matters for "custom" and is converted for each device
 * with its own resolution. */
- (BOOL)applyAccelProfile:(NSString *)profile
                    curve:(AccelerationCurve)curve
                   toKind:(PointerDeviceKind)kind;

- (BOOL)applyTapToClick:(BOOL)enabled;
- (BOOL)applyTwoFingerRightClick:(BOOL)twoFinger threeFingerMiddleClick:(BOOL)threeFinger;
- (BOOL)applyDisableWhileTyping:(BOOL)enabled;

/* Scrolling speed as the pane shows it (1 = libinput's 15 px per scroll
 * unit, larger is faster) to and from "libinput Scrolling Pixel Distance",
 * clamped to the 10..1000 px the driver accepts. */
+ (int)scrollPixelDistanceForSpeed:(double)speed;
+ (double)scrollSpeedForPixelDistance:(int)distance;
+ (double)minimumScrollSpeed;
+ (double)maximumScrollSpeed;

/* libinput feeds the custom acceleration profile raw device units, and X
 * does not expose a touchpad's resolution; only the evdev node named in its
 * "Device Node" property does.  Mice use AccelerationMouseUnitsPerMM.
 * Returns 0 where it cannot be read. */
+ (double)unitsPerMMForKind:(PointerDeviceKind)kind properties:(NSDictionary *)properties;

@end
