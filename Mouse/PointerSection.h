/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>
#import "AccelerationEditor.h"

@class MouseBackend;
@class PointerSection;

@protocol PointerSectionDelegate <NSObject>
- (void)pointerSection:(PointerSection *)section reportFailure:(NSString *)message;
@end

/* The settings of one device class, built the same way for mice,
 * touchpads and trackpoints: a device pop-up, tracking speed, scrolling
 * speed where libinput scales scrolling, handedness and scroll direction,
 * the touchpad's tapping switches, and the acceleration editor for the
 * classes whose curve libinput takes in device units.  Every change goes
 * to all devices of the class through libMouseBackend and is stored under
 * the class's MousePreferences keys, which gershwin-apply-settings applies
 * again at login. */
@interface PointerSection : NSObject <AccelerationEditorDelegate>

@property (nonatomic, readonly) PointerDeviceKind kind;
@property (nonatomic, assign) id<PointerSectionDelegate> delegate;

- (instancetype)initWithKind:(PointerDeviceKind)kind backend:(MouseBackend *)backend;

/* "Mouse", "Trackpad" or "TrackPoint". */
- (NSString *)title;

/* Built once, at the size of the tab it goes into; it follows that tab's
 * size afterwards. */
- (NSView *)viewWithSize:(NSSize)size;

/* The class's devices from the backend's last refresh and the stored
 * preferences; shows the device picked before, or the first one. */
- (void)showDevices:(NSArray *)devices preferences:(NSDictionary *)domain;

@end
