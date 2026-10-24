/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenRecordingOptions.h"

static NSString * const kFormatKey = @"ScreenRecordingFormat";
static NSString * const kFramesPerSecondKey = @"ScreenRecordingFramesPerSecond";
static NSString * const kDownscaleKey = @"ScreenRecordingDownscale";
static NSString * const kShowsPointerKey = @"ScreenRecordingShowsPointer";
static NSString * const kRecordsSoundKey = @"ScreenRecordingRecordsSound";

@implementation ScreenRecordingOptions

@synthesize format, framesPerSecond, downscale, showsPointer, recordsSound;

- (id)init
{
    self = [super init];
    if (self) {
        format = ScreenRecordingGIF;
        // Enough for following what happens on a screen, small as a GIF
        framesPerSecond = 10;
        downscale = 1;
        showsPointer = YES;
        recordsSound = NO;
    }
    return self;
}

+ (instancetype)optionsFromDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    ScreenRecordingOptions *options = [[[self alloc] init] autorelease];

    if ([defaults objectForKey:kFormatKey]) {
        int f = (int)[defaults integerForKey:kFormatKey];
        if (f >= ScreenRecordingGIF && f <= ScreenRecordingMP4)
            [options setFormat:(ScreenRecordingFormat)f];
    }
    if ([defaults integerForKey:kFramesPerSecondKey] > 0)
        [options setFramesPerSecond:(int)[defaults integerForKey:kFramesPerSecondKey]];
    if ([defaults integerForKey:kDownscaleKey] > 0)
        [options setDownscale:(int)[defaults integerForKey:kDownscaleKey]];
    if ([defaults objectForKey:kShowsPointerKey])
        [options setShowsPointer:[defaults boolForKey:kShowsPointerKey]];
    if ([defaults objectForKey:kRecordsSoundKey])
        [options setRecordsSound:[defaults boolForKey:kRecordsSoundKey]];
    return options;
}

- (void)saveToDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:format forKey:kFormatKey];
    [defaults setInteger:framesPerSecond forKey:kFramesPerSecondKey];
    [defaults setInteger:downscale forKey:kDownscaleKey];
    [defaults setBool:showsPointer forKey:kShowsPointerKey];
    [defaults setBool:recordsSound forKey:kRecordsSoundKey];
}

- (id)copyWithZone:(NSZone *)zone
{
    ScreenRecordingOptions *copy = [[[self class] allocWithZone:zone] init];
    [copy setFormat:format];
    [copy setFramesPerSecond:framesPerSecond];
    [copy setDownscale:downscale];
    [copy setShowsPointer:showsPointer];
    [copy setRecordsSound:recordsSound];
    return copy;
}

+ (NSArray *)formatNames
{
    return [NSArray arrayWithObjects:@"GIF", @"APNG", @"WebM", @"MP4", nil];
}

- (NSString *)fileExtension
{
    switch (format) {
    case ScreenRecordingGIF: return @"gif";
    case ScreenRecordingAPNG: return @"apng";
    case ScreenRecordingWebM: return @"webm";
    case ScreenRecordingMP4: return @"mp4";
    }
    return nil;
}

- (BOOL)isVideo
{
    return format == ScreenRecordingWebM || format == ScreenRecordingMP4;
}

- (BOOL)needsConversion
{
    return ![self isVideo];
}

+ (NSRect)recordableArea:(NSRect)area
{
    CGFloat width = MAX(2, floor(NSWidth(area) / 2) * 2);
    CGFloat height = MAX(2, floor(NSHeight(area) / 2) * 2);
    return NSMakeRect(floor(NSMinX(area)), floor(NSMinY(area)), width, height);
}

+ (NSArray *)soundInputArgumentsForSystem:(NSString *)systemName
{
    if ([systemName isEqualToString:@"OpenBSD"])
        return [NSArray arrayWithObjects:@"-f", @"sndio", @"-i", @"default", nil];
    if ([systemName hasSuffix:@"BSD"])
        return [NSArray arrayWithObjects:@"-f", @"oss", @"-i", @"/dev/dsp", nil];
    return [NSArray arrayWithObjects:@"-f", @"alsa", @"-i", @"default", nil];
}

/* Divides both sides by the downscale and keeps them even, as the video
 * encoders need. */
- (NSString *)scaleFilter
{
    return [NSString stringWithFormat:@"scale=trunc(iw/%d/2)*2:trunc(ih/%d/2)*2",
                     downscale, downscale];
}

- (NSArray *)recordingArgumentsForArea:(NSRect)area
                               display:(NSString *)display
                            soundInput:(NSArray *)soundInput
                                output:(NSString *)path
{
    NSRect r = [ScreenRecordingOptions recordableArea:area];
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-hide_banner", @"-loglevel", @"error", @"-y",
        @"-f", @"x11grab",
        @"-draw_mouse", showsPointer ? @"1" : @"0",
        @"-framerate", [NSString stringWithFormat:@"%d", framesPerSecond],
        @"-video_size", [NSString stringWithFormat:@"%dx%d", (int)NSWidth(r), (int)NSHeight(r)],
        @"-i", [NSString stringWithFormat:@"%@+%d,%d", display, (int)NSMinX(r), (int)NSMinY(r)],
        nil];
    BOOL sound = recordsSound && [self isVideo] && [soundInput count] > 0;

    if (sound)
        [args addObjectsFromArray:soundInput];

    if ([self needsConversion]) {
        // Full size and every pixel kept; the palette is made from this
        [args addObjectsFromArray:[NSArray arrayWithObjects:@"-c:v", @"ffv1", nil]];
    } else {
        if (downscale > 1)
            [args addObjectsFromArray:[NSArray arrayWithObjects:@"-vf", [self scaleFilter], nil]];
        if (format == ScreenRecordingMP4) {
            [args addObjectsFromArray:[NSArray arrayWithObjects:
                @"-c:v", @"libx264", @"-preset", @"veryfast", @"-crf", @"23",
                @"-pix_fmt", @"yuv420p", @"-movflags", @"+faststart", nil]];
            if (sound)
                [args addObjectsFromArray:[NSArray arrayWithObjects:@"-c:a", @"aac", nil]];
        } else {
            // Real time, or a large area falls behind and drops frames
            [args addObjectsFromArray:[NSArray arrayWithObjects:
                @"-c:v", @"libvpx-vp9", @"-deadline", @"realtime", @"-cpu-used", @"8",
                @"-crf", @"32", @"-b:v", @"0", @"-pix_fmt", @"yuv420p", nil]];
            if (sound)
                [args addObjectsFromArray:[NSArray arrayWithObjects:@"-c:a", @"libopus", nil]];
        }
    }
    [args addObject:path];
    return args;
}

- (NSArray *)conversionArgumentsFrom:(NSString *)input to:(NSString *)output
{
    if (![self needsConversion])
        return nil;

    NSString *scale = downscale > 1 ? [[self scaleFilter] stringByAppendingString:@","] : @"";
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-hide_banner", @"-loglevel", @"error", @"-y", @"-nostdin",
        @"-i", input, nil];

    if (format == ScreenRecordingGIF) {
        // A palette made from the recording itself, and only changed
        // rectangles redrawn, keeps both the colours and the file size
        NSString *graph = [NSString stringWithFormat:
            @"[0:v]%@split[a][b];[a]palettegen=stats_mode=diff[p];"
            @"[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle", scale];
        [args addObjectsFromArray:[NSArray arrayWithObjects:
            @"-filter_complex", graph, @"-loop", @"0", @"-f", @"gif", nil]];
    } else {
        if (downscale > 1)
            [args addObjectsFromArray:[NSArray arrayWithObjects:@"-vf", [self scaleFilter], nil]];
        [args addObjectsFromArray:[NSArray arrayWithObjects:@"-plays", @"0", @"-f", @"apng", nil]];
    }
    [args addObject:output];
    return args;
}

+ (NSString *)defaultFileNameForDate:(NSDate *)date extension:(NSString *)extension
{
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    [formatter setDateFormat:@"yyyy-MM-dd-HHmmss"];
    return [NSString stringWithFormat:@"Recording-%@.%@",
                     [formatter stringFromDate:date], extension];
}

@end
