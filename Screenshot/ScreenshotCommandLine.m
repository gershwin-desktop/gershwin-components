/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenshotCommandLine.h"
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <unistd.h>

enum {
    ExitSuccess = 0,
    ExitFailure = 1,
    ExitUsage = 2
};

@implementation ScreenshotCommandLine

- (id)initWithArguments:(NSArray *)arguments
{
    self = [super init];
    if (!self)
        return nil;

    mode = ScreenshotModeScreen;
    NSUInteger count = [arguments count];
    for (NSUInteger i = 1; i < count && !error; i++) {
        NSString *arg = [arguments objectAtIndex:i];
        NSString *value = (i + 1 < count) ? [arguments objectAtIndex:i + 1] : nil;

        if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
            showHelp = YES;
            requested = YES;
        } else if ([arg isEqualToString:@"-a"] || [arg isEqualToString:@"--area"]) {
            mode = ScreenshotModeArea;
            requested = YES;
        } else if ([arg isEqualToString:@"-w"] || [arg isEqualToString:@"--window"]) {
            mode = ScreenshotModeWindow;
            requested = YES;
        } else if ([arg isEqualToString:@"-s"] || [arg isEqualToString:@"--screen"]) {
            mode = ScreenshotModeScreen;
            requested = YES;
        } else if ([arg isEqualToString:@"-d"] || [arg isEqualToString:@"--delay"]) {
            requested = YES;
            NSScanner *scanner = value ? [NSScanner scannerWithString:value] : nil;
            if (![scanner scanInt:&delay] || ![scanner isAtEnd] || delay < 0)
                error = [NSString stringWithFormat:@"%@ needs a number of seconds", arg];
            i++;
        } else if ([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--output"]) {
            requested = YES;
            if (!value)
                error = [NSString stringWithFormat:@"%@ needs a file name", arg];
            outputPath = value;
            i++;
        } else if ([arg hasPrefix:@"--"]) {
            // GNUstep options such as --GNU-Debug=... are one argument
        } else if ([arg hasPrefix:@"-"]) {
            // GNUstep defaults come as "-Key value" pairs
            i++;
        } else {
            requested = YES;
            if (outputPath)
                error = [NSString stringWithFormat:@"unexpected argument '%@'", arg];
            outputPath = arg;
        }
    }
    [outputPath retain];
    [error retain];
    return self;
}

- (void)dealloc
{
    [outputPath release];
    [error release];
    [super dealloc];
}

- (BOOL)isRequested
{
    return requested;
}

- (void)printUsageToStream:(FILE *)stream
{
    fprintf(stream,
            "Usage: Screenshot [options] [output-file]\n"
            "\n"
            "Options:\n"
            "  -h, --help         Show this help message\n"
            "  -a, --area         Select an area to capture (drag with the mouse)\n"
            "  -w, --window       Select a window to capture (click on it)\n"
            "  -s, --screen       Capture the whole screen (default)\n"
            "  -d, --delay SEC    Freeze the screen after SEC seconds, then select on it\n"
            "  -o, --output FILE  Save the screenshot to FILE\n"
            "\n"
            "Without an output file, the screenshot is saved on the Desktop.\n"
            "Escape or the right mouse button cancels a selection.\n"
            "Space during an area selection switches to picking a window.\n");
}

- (int)run
{
    if (error) {
        fprintf(stderr, "Screenshot: %s\n\n", [error UTF8String]);
        [self printUsageToStream:stderr];
        return ExitUsage;
    }
    if (showHelp) {
        [self printUsageToStream:stdout];
        return ExitSuccess;
    }

    NSString *path = outputPath ? [outputPath stringByExpandingTildeInPath]
                                : [ScreenshotCapture defaultFilePath];
    if (delay > 0)
        sleep(delay);

    CaptureStatus status;
    NSBitmapImageRep *image = [ScreenshotCapture captureWithMode:mode
                                                    includeFrame:[ScreenshotPreferences includeWindowFrame]
                                                   includeShadow:[ScreenshotPreferences includeWindowShadow]
                                                          status:&status];
    if (status == CaptureStatusCancelled) {
        fprintf(stderr, "Screenshot: cancelled\n");
        return ExitFailure;
    }
    if (!image) {
        fprintf(stderr, "Screenshot: %s\n",
                [[ScreenshotCapture messageForStatus:status] UTF8String]);
        return ExitFailure;
    }
    [ScreenshotCapture flashScreen];

    NSData *png = [ScreenshotCapture PNGDataForImageRep:image];
    NSError *writeError = nil;
    if (!png) {
        fprintf(stderr, "Screenshot: the image could not be converted to PNG\n");
        return ExitFailure;
    }
    if (![png writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        fprintf(stderr, "Screenshot: %s: %s\n", [path UTF8String],
                [[writeError localizedDescription] UTF8String]);
        return ExitFailure;
    }
    return ExitSuccess;
}

@end
