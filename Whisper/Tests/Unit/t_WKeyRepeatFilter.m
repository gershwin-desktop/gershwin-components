/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Holding the record shortcut must toggle once: X11 auto-repeat arrives as
 * further key-downs without key-ups in between.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "WKeyRepeatFilter.h"

static NSString * const kWhat = @"WKeyRepeatFilter";

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    WKeyRepeatFilter *f = [[[WKeyRepeatFilter alloc] init] autorelease];
    int i, repeats = 0;

    PASS(![f noteKeyDown:27 at:1.0], "%s: the first press is a press",
         [kWhat UTF8String]);
    for (i = 0; i < 25; i++)
        if ([f noteKeyDown:27 at:1.7 + i * 0.04]) repeats++;
    PASS(repeats == 25, "holding the key: every further key-down is a repeat");
    PASS(![f noteKeyDown:28 at:2.8], "another key pressed meanwhile is a press");
    /* X sends each repeat as a key-up and a key-down with the same time;
       when the backend sees the two in different reads it passes the
       key-up on. */
    [f noteKeyUp:27 at:2.9];
    PASS([f noteKeyDown:27 at:2.9],
         "a key-up and key-down with the same time are still a repeat");
    [f noteKeyUp:27 at:3.0];
    PASS(![f noteKeyDown:27 at:3.4], "after the release the next press is a press");
    PASS([f noteKeyDown:27 at:4.1], "and holding it again repeats");
    [f reset];
    PASS(![f noteKeyDown:27 at:9.0], "after a reset (key-up lost to another app) "
         "a press is a press");

    [arp release];
    return 0;
}
