/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenshotActionPanel_h
#define ScreenshotActionPanel_h

#import <AppKit/AppKit.h>

typedef enum {
    ScreenshotActionCancel = 0,
    ScreenshotActionSave,
    ScreenshotActionCopy,
    ScreenshotActionRecognizeText
} ScreenshotAction;

/* Asks what to do with a new screenshot.  NSAlert cannot be used: its
 * panels show at most three buttons, which silently dropped Cancel. */
@interface ScreenshotActionPanel : NSPanel

- (ScreenshotAction)runModal;

@end

#endif /* ScreenshotActionPanel_h */
