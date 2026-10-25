/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWSystemScale.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const LWSystemDisplayDefaultsFileName = @"Display.plist";
NSString * const LWScaleSourceKey = @"GSScaleFactorSource";
NSString * const LWScaleSourceRecommended = @"recommended";
NSString * const LWScaleSourceUser = @"user";

NSString *LWSystemDefaultsDirectory(void)
{
    // libs-base looks for GlobalDefaults beside the GNUstep.conf it loaded,
    // which GNUSTEP_CONFIG_FILE may relocate (the isolated test sessions do).
    NSString *confFile = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"GNUSTEP_CONFIG_FILE"];
    NSString *prefs = [confFile length] > 0
        ? [confFile stringByDeletingLastPathComponent] : nil;
    if (prefs == nil) {
        NSArray *libs = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSSystemDomainMask, YES);
        if ([libs count] == 0) {
            NSLog(@"[LoginWindow] No system library directory for the system scale");
            return nil;
        }
        prefs = [[libs objectAtIndex:0] stringByAppendingPathComponent:@"Preferences"];
    }
    return [prefs stringByAppendingPathComponent:@"GlobalDefaults"];
}

static NSString *filePath(NSString *directory)
{
    return [directory stringByAppendingPathComponent:LWSystemDisplayDefaultsFileName];
}

LWSystemScaleState LWSystemScaleStateInDirectory(NSString *directory)
{
    NSData *data = [NSData dataWithContentsOfFile:filePath(directory)];
    if (data == nil) {
        return LWSystemScaleAbsent;
    }
    id plist = nil;
    @try {
        plist = [NSPropertyListSerialization propertyListFromData:data
            mutabilityOption:NSPropertyListImmutable format:NULL
            errorDescription:NULL];
    } @catch (NSException *e) {
        plist = nil;
    }
    // A corrupt file or one without a scale is as good as no file.
    if (![plist isKindOfClass:[NSDictionary class]] ||
        [plist objectForKey:@"GSScaleFactor"] == nil) {
        return LWSystemScaleAbsent;
    }
    return [[plist objectForKey:LWScaleSourceKey]
        isEqual:LWScaleSourceRecommended]
        ? LWSystemScaleRecommended : LWSystemScaleConfigured;
}

BOOL LWWriteRecommendedScale(NSString *directory, double scale)
{
    if (LWSystemScaleStateInDirectory(directory) == LWSystemScaleConfigured) {
        return YES;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directory]) {
        BOOL made = [fm createDirectoryAtPath:directory
            withIntermediateDirectories:YES
            attributes:[NSDictionary dictionaryWithObject:
                [NSNumber numberWithUnsignedLong:0755]
                forKey:NSFilePosixPermissions] error:NULL];
        if (!made) {
            NSLog(@"[LoginWindow] Cannot create %@ for the system scale", directory);
            return NO;
        }
    }
    NSDictionary *content = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithDouble:scale], @"GSScaleFactor",
        LWScaleSourceRecommended, LWScaleSourceKey, nil];
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:content
        format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];

    // A temporary file in the same directory and a rename, so a process that
    // starts meanwhile never reads half a file.
    NSString *target = filePath(directory);
    NSString *temp = [NSString stringWithFormat:@"%@.tmp.%d", target, getpid()];
    int fd = open([temp fileSystemRepresentation],
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    BOOL ok = fd >= 0;
    if (ok) {
        // The umask must not turn 0644 into something libs-base ignores.
        ok = fchmod(fd, 0644) == 0 &&
             write(fd, [data bytes], [data length]) == (ssize_t)[data length] &&
             fsync(fd) == 0;
        close(fd);
    }
    ok = ok && rename([temp fileSystemRepresentation],
                      [target fileSystemRepresentation]) == 0;
    if (!ok) {
        unlink([temp fileSystemRepresentation]);
        NSLog(@"[LoginWindow] Cannot write the system scale to %@ (read-only or no permission)", target);
    }
    return ok;
}
