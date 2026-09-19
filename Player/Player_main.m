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
    // The first network request (on a background thread) sets up
    // GSTcpTune, which reads the user defaults. If the main thread saves a
    // default at that moment, libs-base posts the change notification to
    // GSTcpTune while holding the defaults lock, and both threads wait for
    // each other forever. Setting the class up here, before any other
    // thread runs, avoids that.
    Class tcpTune = NSClassFromString(@"GSTcpTune");
    NSCAssert(tcpTune != Nil, @"libs-base no longer has GSTcpTune");
    [tcpTune class];
    [NSApplication sharedApplication];
    // Files named on the command line reach the delegate through
    // -application:openFiles: while the application finishes launching.
    [NSApp setDelegate:[[PlayerController alloc] init]];
    [pool release];
    return NSApplicationMain(argc, argv);
}
