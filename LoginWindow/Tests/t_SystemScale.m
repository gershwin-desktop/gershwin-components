/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include <sys/stat.h>
#include "../LWSystemScale.m"

static NSString *fresh(NSString *name)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"t_SystemScale_%d_%@", getpid(), name]];
    [[NSFileManager defaultManager] removeFileAtPath:d handler:nil];
    return d;
}

static NSString *fileIn(NSString *d)
{
    return [d stringByAppendingPathComponent:LWSystemDisplayDefaultsFileName];
}

static void put(NSString *d, NSString *text)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:d attributes:nil];
    [text writeToFile:fileIn(d) atomically:NO];
}

static NSDictionary *readFile(NSString *d)
{
    return [NSDictionary dictionaryWithContentsOfFile:fileIn(d)];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *d = fresh(@"absent");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleAbsent,
         "missing directory is absent");
    PASS(LWWriteRecommendedScale(d, 2.0), "write creates the directory");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleRecommended,
         "written file is recommended");
    PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
               [NSNumber numberWithDouble:2.0], "scale stored");
    PASS_EQUAL([readFile(d) objectForKey:LWScaleSourceKey],
               LWScaleSourceRecommended, "source stored");
    struct stat st;
    stat([d fileSystemRepresentation], &st);
    PASS((st.st_mode & 0777) == 0755, "directory is 0755");
    stat([fileIn(d) fileSystemRepresentation], &st);
    PASS((st.st_mode & 0777) == 0644, "file is 0644");
    PASS([[fm directoryContentsAtPath:d] count] == 1,
         "no temporary file is left behind");

    PASS(LWWriteRecommendedScale(d, 1.25), "recommended file is refreshed");
    PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
               [NSNumber numberWithDouble:1.25], "new scale replaced old");

    d = fresh(@"user");
    put(d, @"{ GSScaleFactor = 1.5; GSScaleFactorSource = user; }");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleConfigured,
         "source user is configured");
    PASS(LWWriteRecommendedScale(d, 2.0), "user file: no error");
    PASS([[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 1.5,
         "user file is untouched");

    d = fresh(@"nosource");
    put(d, @"{ GSScaleFactor = 1.75; }");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleConfigured,
         "scale without source is configured");
    LWWriteRecommendedScale(d, 2.0);
    PASS([[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 1.75,
         "administrator file untouched");

    d = fresh(@"corrupt");
    put(d, @"this is { not a plist");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleAbsent,
         "unparsable file is absent");
    PASS(LWWriteRecommendedScale(d, 2.0), "corrupt file is replaced");
    PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
               [NSNumber numberWithDouble:2.0], "replacement is valid");

    d = fresh(@"other");
    put(d, @"{ SomethingElse = 1; }");
    PASS(LWSystemScaleStateInDirectory(d) == LWSystemScaleAbsent,
         "file without a scale is absent");

    [fm removeFileAtPath:fresh(@"absent") handler:nil];
    [fm removeFileAtPath:fresh(@"user") handler:nil];
    [fm removeFileAtPath:fresh(@"nosource") handler:nil];
    [fm removeFileAtPath:fresh(@"corrupt") handler:nil];
    [fm removeFileAtPath:fresh(@"other") handler:nil];
    [arp release];
    return 0;
}
