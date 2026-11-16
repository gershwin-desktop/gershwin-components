/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashConstants.h"
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/utsname.h>
#import <unistd.h>

NSString *GSCrashSanitizeComponent(NSString *in)
{
    if (in == nil || [in length] == 0)
        return @"Unknown";
    NSCharacterSet *bad = [NSCharacterSet
        characterSetWithCharactersInString:@"/\\:*?\"<>| \t\n\r"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < [in length]; i++)
    {
        unichar c = [in characterAtIndex:i];
        if ([bad characterIsMember:c])
            [out appendString:@"_"];
        else
            [out appendFormat:@"%C", c];
    }
    if ([out length] > 64)
        [out deleteCharactersInRange:NSMakeRange(64, [out length] - 64)];
    return [out length] ? out : @"Unknown";
}

NSString *GSCrashBaseDirectory(void)
{
    NSString *base = nil;
    NSString *xdg = [[[NSProcessInfo processInfo] environment] objectForKey:@"XDG_STATE_HOME"];
    if ([xdg length] > 0)
        base = [xdg stringByAppendingPathComponent:@"gnustep/CrashReporter"];
    else
    {
        NSString *home = NSHomeDirectory();
        base = [home stringByAppendingPathComponent:@".local/state/gnustep/CrashReporter"];
    }
    NSError *err = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:base])
    {
        if (![fm createDirectoryAtPath:base
               withIntermediateDirectories:YES
                                attributes:@{ NSFilePosixPermissions : @(0700) }
                                     error:&err])
            NSLog(@"CrashReporter: cannot create base dir %@: %@", base, err);
    }
    return base;
}

NSString *GSCrashNewCrashDirectory(NSString *applicationName, pid_t pid)
{
    NSString *app = GSCrashSanitizeComponent(applicationName);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy-MM-dd-HH-mm-ss"];
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *leaf = [NSString stringWithFormat:@"%@-%d", stamp, (int)pid];
    NSString *dir = [[[GSCrashBaseDirectory() stringByAppendingPathComponent:app]
                      stringByAppendingPathComponent:leaf] copy];
    NSError *err = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir
           withIntermediateDirectories:YES
                            attributes:@{ NSFilePosixPermissions : @(0700) }
                                 error:&err])
        NSLog(@"CrashReporter: cannot create crash dir %@: %@", dir, err);
    return dir;
}

NSString *GSCrashGNUstepBaseVersion(void)
{
    NSString *v = [[NSProcessInfo processInfo]
        environment][@"GNUSTEP_BASE_VERSION"];
    if (v == nil)
        v = @"unknown";
    return v;
}

NSString *GSCrashGNUstepGUIVersion(void)
{
    NSString *v = [[NSProcessInfo processInfo]
        environment][@"GNUSTEP_GUI_VERSION"];
    if (v == nil)
        v = @"unknown";
    return v;
}

NSString *GSCrashOSName(void)
{
    struct utsname u;
    if (uname(&u) != 0)
        return @"Unknown";
    return [NSString stringWithUTF8String:u.sysname];
}

NSString *GSCrashOSVersion(void)
{
    struct utsname u;
    if (uname(&u) != 0)
        return @"Unknown";
    return [NSString stringWithUTF8String:u.release];
}

NSString *GSCrashArchitecture(void)
{
    struct utsname u;
    if (uname(&u) != 0)
        return @"Unknown";
    return [NSString stringWithUTF8String:u.machine];
}
