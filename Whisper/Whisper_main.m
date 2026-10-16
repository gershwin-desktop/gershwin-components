/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/NSApplication.h>
#import <Foundation/NSAutoreleasePool.h>
#import "WhisperController.h"
#import "WApplication.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* WApplication first, so it is the shared application. */
    [WApplication sharedApplication];

    WhisperController *controller = [[WhisperController alloc] init];
    [[NSApplication sharedApplication] setDelegate:controller];

    [pool release];

    [[NSApplication sharedApplication] run];
    return 0;
}
