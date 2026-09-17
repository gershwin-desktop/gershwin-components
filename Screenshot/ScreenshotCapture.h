/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenshotCapture_h
#define ScreenshotCapture_h

#import <Foundation/Foundation.h>
#import "x11_capture.h"

@class NSBitmapImageRep;

typedef enum {
    ScreenshotModeWindow,
    ScreenshotModeArea,
    ScreenshotModeScreen
} ScreenshotMode;

/* Window capture options, persisted in the user defaults and shared by the
 * window and the command line. */
@interface ScreenshotPreferences : NSObject
+ (BOOL)includeWindowFrame;
+ (void)setIncludeWindowFrame:(BOOL)flag;
+ (BOOL)includeWindowShadow;
+ (void)setIncludeWindowShadow:(BOOL)flag;
@end

@interface ScreenshotCapture : NSObject

/* Freezes the screen, lets the user pick a window or an area on the frozen
 * image (nothing to pick for the whole screen), then cuts out the pixels.  Returns nil with *status set when the
 * user cancelled or the capture failed. */
+ (NSBitmapImageRep *)captureWithMode:(ScreenshotMode)mode
                         includeFrame:(BOOL)includeFrame
                        includeShadow:(BOOL)includeShadow
                               status:(CaptureStatus *)status;

/* User-facing explanation of a failed capture. */
+ (NSString *)messageForStatus:(CaptureStatus)status;

+ (NSData *)PNGDataForImageRep:(NSBitmapImageRep *)imageRep;

/* Full path on the Desktop with a name that sorts by capture time. */
+ (NSString *)defaultFilePath;

/* Brief white flash as the shutter feedback. */
+ (void)flashScreen;

@end

#endif /* ScreenshotCapture_h */
