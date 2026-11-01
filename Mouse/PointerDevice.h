/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The classes the Mouse pane has a section for.  libinput exposes the same
 * pointer properties (speed, acceleration profile, scrolling, handedness)
 * on all of them, so most settings are the same per class; what differs is
 * the tapping on touchpads and the units the acceleration curve works in. */
typedef NS_ENUM(NSInteger, PointerDeviceKind) {
    PointerDeviceKindNone = 0,
    PointerDeviceKindMouse,
    PointerDeviceKindTouchpad,
    PointerDeviceKindTrackpoint,
};

/* One X slave pointer driven by libinput, as xinput reports it. */
@interface PointerDevice : NSObject

/* The numeric xinput id; set-prop goes by id because two devices can share
 * a name (a receiver with a mouse and a keyboard behind it). */
@property (nonatomic, readonly, copy) NSString *deviceID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) PointerDeviceKind kind;
@property (nonatomic, readonly, copy) NSDictionary *properties;
/* Device units per millimetre, the unit libinput's custom acceleration
 * profile measures speed in; 0 when unknown (the Custom profile is then not
 * offered for the device). */
@property (nonatomic, readonly) double unitsPerMM;

- (instancetype)initWithID:(NSString *)deviceID
                      name:(NSString *)name
                      kind:(PointerDeviceKind)kind
                properties:(NSDictionary *)properties
                unitsPerMM:(double)unitsPerMM;

/* Takes the name without the "libinput " prefix, e.g. "Accel Speed".  The
 * match is exact because a fragment also matches the driver's read-only
 * "<name> Default" twin and would report the default, not the current
 * value. */
- (NSString *)libinputValue:(NSString *)name;

/* "system", "flat" or "custom", as the pane stores profiles. */
- (BOOL)offersAccelProfile:(NSString *)profile;
- (NSString *)activeAccelProfile;

/* The slave pointers in the output of `xinput list`, in order, as
 * dictionaries with "id" and "name". */
+ (NSArray *)slavePointersInXinputList:(NSString *)output;

/* The output of `xinput list-props`, property name to value text. */
+ (NSDictionary *)propertiesFromXinputListProps:(NSString *)output;

/* The classification rules, in this order:
 *  1. no "libinput Accel Speed" property: not a pointer this pane can
 *     configure (XTEST, keyboards' consumer-control pointers, devices of
 *     other X drivers) -> None;
 *  2. a "libinput Tapping Enabled" property: libinput offers tapping only
 *     on touchpads -> Touchpad;
 *  3. a name naming a pointing stick ("TrackPoint", "Trackpoint",
 *     "TPPS/2", "Pointing Stick", "pointing stick"): libinput does not
 *     expose the udev pointing-stick tag through X -> Trackpoint;
 *  4. anything else -> Mouse. */
+ (PointerDeviceKind)kindForName:(NSString *)name properties:(NSDictionary *)properties;

@end
