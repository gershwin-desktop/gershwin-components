/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenshotController_h
#define ScreenshotController_h

#import <AppKit/AppKit.h>
#import "ScreenshotCapture.h"

@class ScreenshotActionPanel;

@interface ScreenshotController : NSObject
{
    NSWindow *mainWindow;
    NSTextField *statusLabel;
    NSButton *windowButton;
    NSButton *areaButton;
    NSButton *screenButton;
    NSTextField *delayField;
    NSProgressIndicator *progressIndicator;

    ScreenshotActionPanel *actionPanel;
    NSWindow *preferencesWindow;
    NSButton *frameCheckbox;
    NSButton *shadowCheckbox;

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

@end

#endif /* ScreenshotController_h */
