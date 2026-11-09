/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Display number selection, Xephyr lookup, size validation and argument
 * building of the Xephyr launcher.  Headless: works on temporary
 * directories standing in for /tmp/.X11-unix and /tmp. */

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import "Testing.h"
#import "XLXephyr.h"

static NSString *MakeDir(NSString *base, NSString *name)
{
    NSString *path = [base stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return path;
}

static void Touch(NSString *dir, NSString *name, NSString *contents)
{
    [[NSFileManager defaultManager]
        createFileAtPath:[dir stringByAppendingPathComponent:name]
                contents:[contents dataUsingEncoding:NSUTF8StringEncoding]
              attributes:nil];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSString *base = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"xl-test-%d", (int)getpid()]];
    NSString *sockets = MakeDir(base, @"sockets");
    NSString *locks = MakeDir(base, @"locks");
    NSString *myPid = [NSString stringWithFormat:@"%10d\n", (int)getpid()];

    START_SET("display number selection")
    {
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 1,
             "empty system gives :1 (:0 is the real screen)");

        Touch(sockets, @"X1", @"");
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 2,
             "a socket makes the number taken");

        Touch(locks, @".X2-lock", myPid);
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 3,
             "a lock held by a live process makes the number taken");

        /* The highest pid_max on Linux is 2^22, so this pid cannot exist. */
        Touch(locks, @".X3-lock", @"   9999999\n");
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 3,
             "a lock of a dead process without socket is stale, number free");

        Touch(sockets, @"X3", @"");
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 4,
             "a stale lock next to a socket is still taken");

        Touch(locks, @".X4-lock", @"garbage");
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 5,
             "an unreadable lock counts as taken");

        Touch(sockets, @"X0", @"");
        Touch(locks, @".X0-lock", myPid);
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == 5,
             ":0 is never offered");

        NSInteger n;
        for (n = 1; n <= XLMaximumDisplayNumber; n++) {
            Touch(sockets, [NSString stringWithFormat:@"X%ld", (long)n], @"");
        }
        PASS([XLXephyr firstFreeDisplayNumberWithSocketDirectory:sockets
                                                   lockDirectory:locks] == -1,
             "no free number gives -1");
    }
    END_SET("display number selection")

    START_SET("finding the executable")
    {
        NSString *bin = MakeDir(base, @"bin");
        NSString *other = MakeDir(base, @"other");
        Touch(bin, @"Xephyr", @"#!/bin/sh\n");
        chmod([[bin stringByAppendingPathComponent:@"Xephyr"] fileSystemRepresentation], 0755);
        Touch(other, @"Xephyr", @"data");   /* not executable */
        NSString *path = [NSString stringWithFormat:@"%@:%@", other, bin];

        PASS_EQUAL([XLXephyr xephyrPathInSearchPath:path],
                   [bin stringByAppendingPathComponent:@"Xephyr"],
                   "first executable match wins, non-executables are skipped");
        PASS([XLXephyr xephyrPathInSearchPath:other] == nil,
             "missing Xephyr gives nil");
        PASS([XLXephyr xephyrPathInSearchPath:@""] == nil, "empty path gives nil");
        PASS([XLXephyr xephyrPathInSearchPath:nil] == nil, "no path gives nil");
    }
    END_SET("finding the executable")

    START_SET("sizes")
    {
        PASS([XLXephyr dimensionFromString:@"1024"] == 1024, "plain number");
        PASS([XLXephyr dimensionFromString:@" 800 "] == 800, "whitespace trimmed");
        PASS([XLXephyr dimensionFromString:@"12a"] == 0, "trailing junk rejected");
        PASS([XLXephyr dimensionFromString:@"-5"] == 0, "negative rejected");
        PASS([XLXephyr dimensionFromString:@""] == 0, "empty rejected");
        PASS([XLXephyr dimensionFromString:@"1e3"] == 0, "exponent rejected");
        PASS([XLXephyr dimensionFromString:@"99999"] == 0, "too large rejected");

        PASS([XLXephyr validationErrorForWidth:1024 height:768 screenCount:1] == nil,
             "normal size accepted");
        PASS([XLXephyr validationErrorForWidth:0 height:768 screenCount:1] != nil,
             "zero width rejected");
        PASS([XLXephyr validationErrorForWidth:1024 height:XLMinimumDimension - 1
                                    screenCount:1] != nil, "tiny height rejected");
        PASS([XLXephyr validationErrorForWidth:XLMaximumDimension + 1 height:768
                                    screenCount:1] != nil, "huge width rejected");
        PASS([XLXephyr validationErrorForWidth:1024 height:768 screenCount:0] != nil,
             "zero screens rejected");
        PASS([XLXephyr validationErrorForWidth:1024 height:768
                                    screenCount:XLMaximumScreenCount + 1] != nil,
             "too many screens rejected");
    }
    END_SET("sizes")

    START_SET("arguments")
    {
        NSArray *one = [XLXephyr argumentsForDisplayNumber:7 width:1280 height:720
                                               screenCount:1];
        NSArray *expect = [NSArray arrayWithObjects:
            @":7", @"-title", @"Xephyr :7", @"-screen", @"1280x720", nil];
        PASS_EQUAL(one, expect, "single screen arguments");

        NSArray *two = [XLXephyr argumentsForDisplayNumber:12 width:800 height:600
                                               screenCount:2];
        expect = [NSArray arrayWithObjects:
            @":12", @"-title", @"Xephyr :12",
            @"-screen", @"800x600", @"-screen", @"800x600", nil];
        PASS_EQUAL(two, expect, "every screen gets its own -screen");

        PASS_EQUAL([XLXephyr displayStringForNumber:5], @":5", "display string");

        NSDictionary *env = [XLXephyr environmentForDisplayNumber:5
            baseEnvironment:[NSDictionary dictionaryWithObjectsAndKeys:
                @":0", @"DISPLAY", @"/x", @"XAUTHORITY", @"1", @"KEEP", nil]];
        PASS_EQUAL([env objectForKey:@"DISPLAY"], @":5", "DISPLAY points at Xephyr");
        PASS([env objectForKey:@"XAUTHORITY"] == nil,
             "the host's X authority must not leak into the nested display");
        PASS_EQUAL([env objectForKey:@"KEEP"], @"1", "other variables kept");
    }
    END_SET("arguments")

    [[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
    [arp release];
    return 0;
}
