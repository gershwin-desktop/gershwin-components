/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRPrivilegedTask.h"
#include <unistd.h>

@implementation PRToolLocator

+ (NSString *)pathForTool:(NSString *)name
{
    static NSArray *directories = nil;
    if (directories == nil)
        directories = @[@"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin",
                        @"/usr/local/bin", @"/usr/local/sbin",
                        @"/System/Library/Tools"];

    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *directory in directories) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([manager isExecutableFileAtPath:path])
            return path;
    }
    return nil;
}

@end

@implementation PRPrivilegedTask

+ (BOOL)isRoot
{
    return geteuid() == 0;
}

+ (NSString *)askPassHelper
{
    NSString *helper = [[[NSProcessInfo processInfo] environment]
                        objectForKey:@"SUDO_ASKPASS"];
    if ([helper length] == 0)
        return nil;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper])
        return nil;
    return helper;
}

+ (BOOL)isElevationAvailable
{
    if ([self isRoot])
        return YES;
    return [PRToolLocator pathForTool:@"sudo"] != nil &&
           [self askPassHelper] != nil;
}

+ (NSString *)elevationProblem
{
    if ([self isElevationAvailable])
        return nil;
    if ([PRToolLocator pathForTool:@"sudo"] == nil)
        return @"sudo is not installed, so the profiler cannot obtain the "
               @"rights the sampling tools need.";
    return @"No graphical password helper is configured. Set SUDO_ASKPASS to "
           @"an askpass program so that sudo can ask for the password.";
}

+ (NSTask *)taskForTool:(NSString *)toolPath
              arguments:(NSArray *)arguments
               elevated:(BOOL)elevated
{
    NSTask *task = [[NSTask alloc] init];

    if (!elevated || [self isRoot]) {
        [task setLaunchPath:toolPath];
        [task setArguments:arguments];
        return task;
    }

    NSString *sudo = [PRToolLocator pathForTool:@"sudo"];
    if (sudo == nil)
        return nil;

    NSMutableArray *sudoArguments = [NSMutableArray arrayWithObjects:
                                     @"-A", @"--", toolPath, nil];
    [sudoArguments addObjectsFromArray:arguments];
    [task setLaunchPath:sudo];
    [task setArguments:sudoArguments];
    return task;
}

+ (int)runTool:(NSString *)toolPath
     arguments:(NSArray *)arguments
      elevated:(BOOL)elevated
{
    NSTask *task = [self taskForTool:toolPath arguments:arguments
                            elevated:elevated];
    if (task == nil)
        return -1;

    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return -1;
    }
    [task waitUntilExit];
    return [task terminationStatus];
}

@end
