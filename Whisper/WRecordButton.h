/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WRECORDBUTTON_H
#define WRECORDBUTTON_H

#import <AppKit/AppKit.h>

/// The one button that both starts and stops a recording.
///
/// It is an ordinary themed button, so the desktop draws the same aqua bezel
/// every other button has.  What is its own is the image: the application
/// icon at rest, a stop square while the microphone is open, so a single
/// control does both jobs and its state is readable from the control itself.
///
/// The title is the button's accessible name and is never drawn (the button
/// is image-only).  It follows the state, which is also what the UI tests
/// match this control on.
@interface WRecordButton : NSButton
{
    BOOL recording;
    NSImage *recordImage;
    NSImage *stopImage;
}

/// YES while the microphone is open: the icon becomes a stop square.
- (void)setRecording:(BOOL)flag;
- (BOOL)isRecording;

@end
#endif
