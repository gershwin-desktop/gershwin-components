/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenshotController_h
#define ScreenshotController_h

#import <AppKit/AppKit.h>
#import "ScreenshotCapture.h"
#import "RecordingFrame.h"
#import "ScreenRecorder.h"

@class ScreenshotActionPanel;

@interface ScreenshotController : NSObject <RecordingFrameDelegate, ScreenRecorderDelegate>
{
    NSWindow *mainWindow;
    NSTextField *statusLabel;
    NSButton *windowButton;
    NSButton *areaButton;
    NSButton *screenButton;
    NSButton *recordButton;
    NSTextField *delayField;
    NSProgressIndicator *progressIndicator;

    ScreenshotActionPanel *actionPanel;
    NSWindow *preferencesWindow;
    NSButton *frameCheckbox;
    NSButton *shadowCheckbox;
    NSPopUpButton *framesPerSecondPopUp;
    NSPopUpButton *sizePopUp;
    NSButton *pointerCheckbox;
    NSButton *soundCheckbox;

    RecordingFrame *recordingFrame;
    ScreenRecorder *recorder;
    NSTimer *recordingTimer;
    int recordingCountdown;

    ScreenshotMode pendingMode;
    int remainingDelay;
    NSTimer *countdownTimer;
    NSArray *windowsHiddenForCapture;

    NSBitmapImageRep *capturedImage;
    NSData *capturedPNG;

    NSTask *ocrTask;
    NSString *ocrInputPath;
}

- (IBAction)takeWindowScreenshot:(id)sender;
- (IBAction)takeAreaScreenshot:(id)sender;
- (IBAction)takeScreenScreenshot:(id)sender;
- (IBAction)showPreferences:(id)sender;
- (IBAction)toggleIncludeFrame:(id)sender;
- (IBAction)toggleIncludeShadow:(id)sender;
- (IBAction)recordArea:(id)sender;
- (IBAction)recordingOptionChanged:(id)sender;

@end

#endif /* ScreenshotController_h */
