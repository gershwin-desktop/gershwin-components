/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ScreenRecordingOptions.h"

/* The value following flag in args, or nil. */
static NSString *
valueOf(NSArray *args, NSString *flag)
{
  NSUInteger i = [args indexOfObject: flag];
  return (i == NSNotFound || i + 1 >= [args count]) ? nil : [args objectAtIndex: i + 1];
}

static BOOL
has(NSArray *args, NSString *s)
{
  return [args containsObject: s];
}

static ScreenRecordingOptions *
options(ScreenRecordingFormat f, int fps, int scale, BOOL pointer, BOOL sound)
{
  ScreenRecordingOptions *o = [[[ScreenRecordingOptions alloc] init] autorelease];
  [o setFormat: f];
  [o setFramesPerSecond: fps];
  [o setDownscale: scale];
  [o setShowsPointer: pointer];
  [o setRecordsSound: sound];
  return o;
}

int
main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSArray *alsa = [NSArray arrayWithObjects: @"-f", @"alsa", @"-i", @"default", nil];
  NSArray *a;
  NSRect r;

  START_SET("formats")
    PASS([[ScreenRecordingOptions formatNames] count] == 4, "four formats");
    PASS([[options(ScreenRecordingGIF, 10, 1, YES, NO) fileExtension] isEqual: @"gif"], "GIF");
    PASS([[options(ScreenRecordingAPNG, 10, 1, YES, NO) fileExtension] isEqual: @"apng"], "APNG");
    PASS([[options(ScreenRecordingWebM, 10, 1, YES, NO) fileExtension] isEqual: @"webm"], "WebM");
    PASS([[options(ScreenRecordingMP4, 10, 1, YES, NO) fileExtension] isEqual: @"mp4"], "MP4");
    PASS([options(ScreenRecordingGIF, 10, 1, YES, NO) needsConversion]
         && ![options(ScreenRecordingMP4, 10, 1, YES, NO) needsConversion],
         "animated images are converted, videos are not");
  END_SET("formats")

  START_SET("area")
    r = [ScreenRecordingOptions recordableArea: NSMakeRect(101, 51, 641, 401)];
    PASS(NSEqualRects(r, NSMakeRect(101, 51, 640, 400)), "odd sizes are made even, the place stays");
    r = [ScreenRecordingOptions recordableArea: NSMakeRect(0, 0, 1, 1)];
    PASS(NSWidth(r) >= 2 && NSHeight(r) >= 2, "never smaller than 2 x 2");
  END_SET("area")

  START_SET("recording a video")
    a = [options(ScreenRecordingMP4, 24, 1, YES, NO)
          recordingArgumentsForArea: NSMakeRect(100, 50, 640, 400)
                            display: @":0"
                         soundInput: alsa
                             output: @"/tmp/out.mp4"];
    PASS([valueOf(a, @"-f") isEqual: @"x11grab"], "grabs the X screen");
    PASS([valueOf(a, @"-video_size") isEqual: @"640x400"], "the size of the area");
    PASS([a containsObject: @":0+100,50"], "at the place of the area");
    PASS([valueOf(a, @"-framerate") isEqual: @"24"], "at the frame rate");
    PASS([valueOf(a, @"-draw_mouse") isEqual: @"1"], "with the pointer");
    PASS([valueOf(a, @"-c:v") isEqual: @"libx264"] && [valueOf(a, @"-pix_fmt") isEqual: @"yuv420p"],
         "MP4 is H.264 that every player plays");
    PASS(!has(a, @"alsa"), "no sound unless asked for");
    PASS([[a lastObject] isEqual: @"/tmp/out.mp4"], "into the output file");
    PASS(!has(a, @"-nostdin"), "ffmpeg reads q on its standard input to stop");

    a = [options(ScreenRecordingWebM, 10, 2, NO, YES)
          recordingArgumentsForArea: NSMakeRect(0, 0, 800, 600)
                            display: @":1"
                         soundInput: alsa
                             output: @"/tmp/out.webm"];
    PASS([valueOf(a, @"-draw_mouse") isEqual: @"0"], "without the pointer");
    PASS([valueOf(a, @"-c:v") isEqual: @"libvpx-vp9"], "WebM is VP9");
    PASS(has(a, @"alsa") && [valueOf(a, @"-c:a") isEqual: @"libopus"], "sound when asked for, Opus in WebM");
    PASS([valueOf(a, @"-vf") rangeOfString: @"scale="].location != NSNotFound, "made smaller");
  END_SET("recording a video")

  START_SET("recording an animated image")
    a = [options(ScreenRecordingGIF, 10, 2, YES, YES)
          recordingArgumentsForArea: NSMakeRect(0, 0, 800, 600)
                            display: @":0"
                         soundInput: alsa
                             output: @"/tmp/raw.mkv"];
    PASS([valueOf(a, @"-c:v") isEqual: @"ffv1"], "recorded losslessly first");
    PASS(!has(a, @"alsa"), "an image has no sound");
    PASS(valueOf(a, @"-vf") == nil, "made smaller only when converted");

    a = [options(ScreenRecordingGIF, 10, 2, YES, NO)
          conversionArgumentsFrom: @"/tmp/raw.mkv" to: @"/tmp/out.gif"];
    PASS([valueOf(a, @"-i") isEqual: @"/tmp/raw.mkv"] && [[a lastObject] isEqual: @"/tmp/out.gif"],
         "from the recording to the image");
    PASS([valueOf(a, @"-filter_complex") rangeOfString: @"palettegen"].location != NSNotFound
         && [valueOf(a, @"-filter_complex") rangeOfString: @"paletteuse"].location != NSNotFound,
         "a GIF gets a palette made for it");
    PASS([valueOf(a, @"-filter_complex") rangeOfString: @"scale="].location != NSNotFound,
         "and is made smaller");
    PASS([valueOf(a, @"-loop") isEqual: @"0"], "a GIF loops");

    a = [options(ScreenRecordingAPNG, 10, 1, YES, NO)
          conversionArgumentsFrom: @"/tmp/raw.mkv" to: @"/tmp/out.apng"];
    PASS([valueOf(a, @"-f") isEqual: @"apng"] && [valueOf(a, @"-plays") isEqual: @"0"],
         "an APNG loops");
    PASS([options(ScreenRecordingMP4, 10, 1, YES, NO)
           conversionArgumentsFrom: @"a" to: @"b"] == nil, "a video needs no conversion");
  END_SET("recording an animated image")

  START_SET("sound input")
    PASS([[ScreenRecordingOptions soundInputArgumentsForSystem: @"Linux"] isEqual: alsa],
         "ALSA on Linux");
    a = [ScreenRecordingOptions soundInputArgumentsForSystem: @"FreeBSD"];
    PASS([valueOf(a, @"-f") isEqual: @"oss"] && [valueOf(a, @"-i") isEqual: @"/dev/dsp"], "OSS on FreeBSD");
    a = [ScreenRecordingOptions soundInputArgumentsForSystem: @"OpenBSD"];
    PASS([valueOf(a, @"-f") isEqual: @"sndio"], "sndio on OpenBSD");
  END_SET("sound input")

  START_SET("file name")
    PASS([[ScreenRecordingOptions defaultFileNameForDate:
             [NSDate dateWithString: @"2026-10-12 14:03:09 +0000"] extension: @"gif"]
           hasSuffix: @".gif"],
         "named after the moment, with the format's extension");
  END_SET("file name")

  [arp release];
  return 0;
}
