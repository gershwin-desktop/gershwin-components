/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenRecordingOptions_h
#define ScreenRecordingOptions_h

#import <Foundation/Foundation.h>

typedef enum {
    ScreenRecordingGIF = 0,
    ScreenRecordingAPNG = 1,
    ScreenRecordingWebM = 2,
    ScreenRecordingMP4 = 3
} ScreenRecordingFormat;

/* How a screen recording is made, and the ffmpeg command lines that make
 * it.  Pure Foundation, so the command lines can be checked without a
 * display or ffmpeg. */
@interface ScreenRecordingOptions : NSObject <NSCopying>
{
    ScreenRecordingFormat format;
    int framesPerSecond;
    int downscale;
    BOOL showsPointer;
    BOOL recordsSound;
}

@property (nonatomic, assign) ScreenRecordingFormat format;
@property (nonatomic, assign) int framesPerSecond;
/* 1 keeps the size, 2 halves it, 3 makes it a third. */
@property (nonatomic, assign) int downscale;
@property (nonatomic, assign) BOOL showsPointer;
/* Only video formats carry sound. */
@property (nonatomic, assign) BOOL recordsSound;

+ (instancetype)optionsFromDefaults;
- (void)saveToDefaults;

/* Display names, indexed by ScreenRecordingFormat. */
+ (NSArray *)formatNames;
- (NSString *)fileExtension;
- (BOOL)isVideo;
/* Animated images are recorded losslessly first and converted when the
 * recording stops, so their palette is made from the whole recording. */
- (BOOL)needsConversion;

/* The largest area at the same place with an even width and height, which
 * the video encoders need; root pixels, y down. */
+ (NSRect)recordableArea:(NSRect)area;

/* Sound input for ffmpeg on this kind of system (uname -s). */
+ (NSArray *)soundInputArgumentsForSystem:(NSString *)systemName;

/* Records area (root pixels, y down) of display until ffmpeg reads "q"
 * on its standard input. */
- (NSArray *)recordingArgumentsForArea:(NSRect)area
                               display:(NSString *)display
                            soundInput:(NSArray *)soundInput
                                output:(NSString *)path;
/* Turns the lossless recording into the animated image; nil for formats
 * that need no conversion. */
- (NSArray *)conversionArgumentsFrom:(NSString *)input to:(NSString *)output;

+ (NSString *)defaultFileNameForDate:(NSDate *)date extension:(NSString *)extension;

@end

#endif /* ScreenRecordingOptions_h */
