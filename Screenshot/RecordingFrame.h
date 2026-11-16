/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef RecordingFrame_h
#define RecordingFrame_h

#import <AppKit/AppKit.h>
#import "ScreenRecordingOptions.h"

@class RecordingFrame;

@protocol RecordingFrameDelegate
- (void)recordingFrameRecord:(RecordingFrame *)frame;
- (void)recordingFrameStop:(RecordingFrame *)frame;
- (void)recordingFrameCancel:(RecordingFrame *)frame;
- (void)recordingFrame:(RecordingFrame *)frame didChooseFormat:(ScreenRecordingFormat)format;
@end

typedef enum {
    RecordingFrameIdle,
    RecordingFrameCountingDown,
    RecordingFrameRecording,
    RecordingFrameSaving
} RecordingFrameState;

/* What is recorded, shown as a frame around it on the screen, with the
 * controls in a bar underneath.  The frame and the bar lie outside the
 * area, so they never end up in the recording.  Before recording the frame
 * is moved by its bar and resized by its edges and corners. */
@interface RecordingFrame : NSObject
{
    NSRect area;
    NSArray *edges;
    NSWindow *bar;
    NSPopUpButton *formatPopUp;
    NSTextField *infoLabel;
    NSTextField *widthField;
    NSTextField *timesLabel;
    NSTextField *heightField;
    NSButton *cancelButton;
    NSButton *recordButton;
    NSProgressIndicator *spinner;
    RecordingFrameState state;
    BOOL shown;
    BOOL placingBar;
    BOOL followingBar;
    NSPoint placedBarOrigin;
    NSDate *lastPlacement;
    id<RecordingFrameDelegate> delegate;
}

/* area is in screen coordinates, as window frames are. */
- (id)initWithArea:(NSRect)area
            format:(ScreenRecordingFormat)format
          delegate:(id<RecordingFrameDelegate>)delegate;

- (void)show;
- (void)close;

- (NSRect)area;
- (void)setArea:(NSRect)area;
/* The area in X root pixels, y down, as ffmpeg grabs it. */
- (NSRect)rootArea;

- (RecordingFrameState)recordingState;
- (void)setRecordingState:(RecordingFrameState)state;
- (void)showCountdown:(int)seconds;
- (void)showElapsedTime:(NSTimeInterval)seconds;

@end

#endif /* RecordingFrame_h */
