/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PlayerController.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    // Files named on the command line reach the delegate through
    // -application:openFiles: while the application finishes launching.
    [NSApp setDelegate:[[PlayerController alloc] init]];
    [pool release];
    return NSApplicationMain(argc, argv);
}
