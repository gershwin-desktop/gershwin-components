/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>
#import "CurveView.h"
#import "PointerDevice.h"

@class AccelerationEditor;

@protocol AccelerationEditorDelegate <NSObject>
/* Puts the profile on the devices and stores it; the editor only takes it
 * as the device's state when this returns YES. */
- (BOOL)accelerationEditor:(AccelerationEditor *)editor
              applyProfile:(NSString *)profile
                     curve:(AccelerationCurve)curve;
/* After an applied profile became the editor's profile. */
- (void)accelerationEditorDidChangeProfile:(AccelerationEditor *)editor;
@end

/* The acceleration profile pop-up (System, Flat, Custom), the curve and its
 * four parameters for one device class.  Mice and touchpads use the same
 * editor; only the class's speed scale, gain range and built-in profiles
 * differ (AccelerationCurve.h).  The built-in profiles are shown read-only
 * as what they do at the current speed setting, so a custom curve can be
 * compared with them. */
@interface AccelerationEditor : NSObject <CurveViewDelegate>

@property (nonatomic, readonly) PointerDeviceKind kind;
@property (nonatomic, assign) id<AccelerationEditorDelegate> delegate;
/* "system", "flat" or "custom"; what the shown device runs. */
@property (nonatomic, readonly, copy) NSString *profile;

- (instancetype)initWithKind:(PointerDeviceKind)kind;

/* Height the editor needs at least below its top edge. */
+ (CGFloat)minimumHeight;

/* Lays the editor out in view between y = 0 and top; the curve takes the
 * height the slider column leaves and follows the view's size. */
- (void)buildInView:(NSView *)view top:(CGFloat)top;

/* The device whose profile is shown and which profiles it offers, and the
 * last custom curve stored for its class. */
- (void)showDevice:(PointerDevice *)device storedCurve:(AccelerationCurve)curve;

/* The class's tracking speed, which the built-in profiles scale with. */
- (void)setSpeedSetting:(double)speed;

@end
