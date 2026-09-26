/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "CurveView.h"

@class MouseBackend;

@interface MouseController : NSObject <CurveViewDelegate>
{
    NSView *mainView;
    NSBox *mouseBox;
    NSBox *trackpadBox;

    /* Tabs inside the trackpad box */
    NSTabView *trackpadTabView;

    /* General tab controls */
    NSSlider *trackpadSpeedSlider;
    NSTextField *trackpadSpeedLabel;
    NSButton *naturalScrollingCheckbox;
    NSButton *tapToClickCheckbox;
    NSButton *twoFingerRightClickCheckbox;
    NSButton *threeFingerMiddleClickCheckbox;
    NSButton *disableWhileTypingCheckbox;

    /* Acceleration Curve tab controls */
    CurveView *curveView;
    NSPopUpButton *curveProfilePopup;
    NSTextField *precisionLabel;
    NSTextField *precisionValue;
    NSSlider *precisionSlider;
    NSTextField *startLabel;
    NSTextField *startValue;
    NSSlider *startSlider;
    NSTextField *endLabel;
    NSTextField *endValue;
    NSSlider *endSlider;
    NSTextField *fastLabel;
    NSTextField *fastValue;
    NSSlider *fastSlider;
    NSButton *applyCurveButton;
    NSButton *restoreCurveButton;

    /* Mouse controls */
    NSSlider *mouseSpeedSlider;
    NSTextField *mouseSpeedLabel;
    NSButton *leftHandedCheckbox;

    /* TrackPoint controls */
    NSSlider *trackpointSpeedSlider;
    NSTextField *trackpointSpeedLabel;

    NSTextField *statusLabel;

    MouseBackend *backend;
    double touchpadUnitsPerMM;

    NSString *currentCurveProfile;
    AccelerationCurve pendingCurve;
    AccelerationCurve savedCurve;
    BOOL isRefreshing;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshFromSystem;
- (IBAction)settingChanged:(id)sender;
- (IBAction)curveProfileChanged:(id)sender;
- (IBAction)applyCurve:(id)sender;
- (IBAction)restoreCurve:(id)sender;

@end
