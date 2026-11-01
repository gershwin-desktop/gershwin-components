/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "DisplaySystemDefaults.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const DisplaySystemDefaultsFileName = @"Display.plist";
NSString * const DisplayScaleFactorKey = @"GSScaleFactor";
NSString * const DisplayScaleSourceKey = @"GSScaleFactorSource";
NSString * const DisplayScaleSourceRecommended = @"recommended";
NSString * const DisplayScaleSourceUser = @"user";

static void setProblem(NSString **problem, NSString *text)
{
    if (problem) *problem = text;
}

NSString *DisplaySystemDefaultsDirectory(void)
{
    // libs-base looks for GlobalDefaults beside the GNUstep.conf it loaded,
    // which GNUSTEP_CONFIG_FILE relocates in the isolated test sessions.
    NSString *confFile = [[[NSProcessInfo processInfo] environment]
        objectForKey:@"GNUSTEP_CONFIG_FILE"];
    NSString *prefs;
    if ([confFile length] > 0) {
        prefs = [confFile stringByDeletingLastPathComponent];
    } else {
        NSArray *libs = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSSystemDomainMask, YES);
        if ([libs count] == 0) return nil;
        prefs = [[libs objectAtIndex:0] stringByAppendingPathComponent:@"Preferences"];
    }
    return [prefs stringByAppendingPathComponent:@"GlobalDefaults"];
}

NSString *DisplaySystemDefaultsPath(void)
{
    NSString *directory = DisplaySystemDefaultsDirectory();
    return directory
        ? [directory stringByAppendingPathComponent:DisplaySystemDefaultsFileName]
        : nil;
}

static NSDictionary *readFile(NSString *path)
{
    NSData *data = [path length] ? [NSData dataWithContentsOfFile:path] : nil;
    if (data == nil) return nil;
    id plist = nil;
    @try {
        plist = [NSPropertyListSerialization propertyListFromData:data
            mutabilityOption:NSPropertyListImmutable format:NULL
            errorDescription:NULL];
    } @catch (NSException *e) {
        plist = nil;
    }
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

DisplaySystemScaleState DisplaySystemScaleStateAtPath(NSString *path)
{
    NSDictionary *plist = readFile(path);
    // A corrupt file or one without a scale is as good as no file.
    if ([plist objectForKey:DisplayScaleFactorKey] == nil) {
        return DisplaySystemScaleAbsent;
    }
    return [[plist objectForKey:DisplayScaleSourceKey]
        isEqual:DisplayScaleSourceRecommended]
        ? DisplaySystemScaleRecommended : DisplaySystemScaleConfigured;
}

NSDictionary *DisplaySystemDefaultsBySettingScale(NSDictionary *existing,
                                                  double scale,
                                                  NSString *source)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:existing];
    [d setObject:[NSNumber numberWithDouble:scale] forKey:DisplayScaleFactorKey];
    [d setObject:source forKey:DisplayScaleSourceKey];
    return d;
}

BOOL DisplayWriteSystemScale(NSString *path, double scale, NSString *source,
                             NSString **problem)
{
    if ([path length] == 0) {
        setProblem(problem, @"The system defaults directory is unknown.");
        return NO;
    }
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directory]
        && ![fm createDirectoryAtPath:directory
          withIntermediateDirectories:YES
                           attributes:[NSDictionary dictionaryWithObject:
                                          [NSNumber numberWithUnsignedLong:0755]
                                                                  forKey:NSFilePosixPermissions]
                                error:NULL]) {
        setProblem(problem, [NSString stringWithFormat:@"Cannot create %@.", directory]);
        return NO;
    }
    NSDictionary *content = DisplaySystemDefaultsBySettingScale(readFile(path),
                                                                scale, source);
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:content
        format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
    if (data == nil) {
        setProblem(problem, @"The system defaults cannot be serialized.");
        return NO;
    }

    NSString *temp = [path stringByAppendingFormat:@".%d.tmp", (int)getpid()];
    const char *ctemp = [temp fileSystemRepresentation];
    int fd = open(ctemp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    BOOL ok = fd >= 0;
    if (ok) {
        // fchmod rather than trusting the umask: libs-base ignores a
        // defaults file that group or others can write.
        ok = fchmod(fd, 0644) == 0
             && write(fd, [data bytes], [data length]) == (ssize_t)[data length]
             && fsync(fd) == 0;
        if (close(fd) != 0) ok = NO;
    }
    ok = ok && rename(ctemp, [path fileSystemRepresentation]) == 0;
    if (!ok) {
        int err = errno;
        unlink(ctemp);
        setProblem(problem, [NSString stringWithFormat:@"Cannot write %@: %s.",
                             path, strerror(err)]);
    }
    return ok;
}

BOOL DisplayWriteRecommendedScale(NSString *path, double scale,
                                  NSString **problem)
{
    if (DisplaySystemScaleStateAtPath(path) == DisplaySystemScaleConfigured) {
        return YES;
    }
    return DisplayWriteSystemScale(path, scale, DisplayScaleSourceRecommended,
                                   problem);
}
