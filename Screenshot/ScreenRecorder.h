/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenRecorder_h
#define ScreenRecorder_h

#import <Foundation/Foundation.h>
#import "ScreenRecordingOptions.h"

@class ScreenRecorder;

@protocol ScreenRecorderDelegate
- (void)screenRecorderIsConverting:(ScreenRecorder *)recorder;
/* The recording is in a temporary file, which the delegate moves away or
 * gives back with -discardFile. */
- (void)screenRecorder:(ScreenRecorder *)recorder didFinishWithFile:(NSString *)path;
- (void)screenRecorder:(ScreenRecorder *)recorder didFailWithMessage:(NSString *)message;
@end

/* Records an area of the screen with ffmpeg: started, stopped by asking
 * ffmpeg to finish ("q" on its standard input, so the file is complete),
 * then converted when the format needs it. */
@interface ScreenRecorder : NSObject
{
    ScreenRecordingOptions *options;
    NSRect area;
    id<ScreenRecorderDelegate> delegate;
    NSString *ffmpeg;
    NSString *directory;
    NSString *recordingPath;
    NSString *outputPath;
    NSTask *task;
    NSFileHandle *input;
    NSMutableData *errors;
    NSDate *startDate;
    BOOL stopping;
    BOOL converting;
}

/* The ffmpeg found on PATH, or nil. */
+ (NSString *)ffmpegPath;

/* area is in root pixels, y down. */
- (id)initWithOptions:(ScreenRecordingOptions *)options
                 area:(NSRect)area
             delegate:(id<ScreenRecorderDelegate>)delegate;

/* NO with message set when ffmpeg could not be started. */
- (BOOL)startReturningError:(NSString **)message;
- (void)stop;
/* Stops without keeping anything; the delegate hears no more. */
- (void)cancel;
- (NSTimeInterval)elapsedTime;
- (BOOL)isRecording;
- (void)discardFile;

@end

#endif /* ScreenRecorder_h */
