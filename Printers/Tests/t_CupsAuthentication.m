/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* A user who may manage printers still has to give a password to CUPS, which
 * cannot ask on a terminal.  The session's SUDO_ASKPASS program asks in a
 * window; what it prints is the password, a failure or an empty answer is a
 * cancel.  Tested with small stand-in programs. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "CupsAuthentication.h"

static NSString *Script(NSString *dir, NSString *name, NSString *body)
{
    NSString *path = [dir stringByAppendingPathComponent:name];
    [[@"#!/bin/sh\n" stringByAppendingString:body] writeToFile:path atomically:YES
                                                      encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] setAttributes:
        [NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions]
                                     ofItemAtPath:path error:NULL];
    return path;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cupsauth-%d", (int)getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    START_SET("the password is what the helper prints")
    {
        PASS_EQUAL([CupsAuthentication passwordFromHelper:Script(dir, @"ok", @"echo 's3 cret'\n")
                                                   prompt:@"p"],
                   @"s3 cret", "the line, without its newline");
        PASS_EQUAL([CupsAuthentication passwordFromHelper:
                       Script(dir, @"echoes", @"printf '%s' \"$1\"\n") prompt:@"Prompt text"],
                   @"Prompt text", "the helper is given the prompt");
    }
    END_SET("the password is what the helper prints")

    START_SET("anything but a password is a cancel")
    {
        PASS([CupsAuthentication passwordFromHelper:Script(dir, @"fail", @"echo 'x'; exit 1\n")
                                             prompt:@"p"] == nil, "the helper failed (Cancel)");
        PASS([CupsAuthentication passwordFromHelper:Script(dir, @"empty", @"echo ''\n")
                                             prompt:@"p"] == nil, "an empty answer");
        PASS([CupsAuthentication passwordFromHelper:[dir stringByAppendingPathComponent:@"missing"]
                                             prompt:@"p"] == nil, "no such helper");
        PASS([CupsAuthentication passwordFromHelper:nil prompt:@"p"] == nil, "no helper set");
    }
    END_SET("anything but a password is a cancel")

    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    [arp release];
    return 0;
}
