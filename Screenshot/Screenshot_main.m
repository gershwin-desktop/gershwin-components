/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "ScreenshotController.h"
#import "ScreenshotCommandLine.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

    ScreenshotCommandLine *commandLine = [[[ScreenshotCommandLine alloc]
        initWithArguments:[[NSProcessInfo processInfo] arguments]] autorelease];
    if ([commandLine isRequested]) {
        // Not through -run: finishing launching would register the app and,
        // with a copy already open, silently hand over to that copy
        int status = [commandLine run];
        x11_cleanup();
        [pool release];
        return status;
    }

    [NSApp setDelegate:[[ScreenshotController alloc] init]];
    [pool release];
    [NSApp run];
    return 0;
}
