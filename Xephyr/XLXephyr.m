/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "XLXephyr.h"
#import <errno.h>
#import <signal.h>
#import <unistd.h>

const NSInteger XLMinimumDisplayNumber = 1;
const NSInteger XLMaximumDisplayNumber = 255;
const NSInteger XLMinimumDimension = 100;
const NSInteger XLMaximumDimension = 8192;
const NSInteger XLMaximumScreenCount = 4;

/* Every X server on these systems uses these, whatever the display. */
static NSString *const kSocketDirectory = @"/tmp/.X11-unix";
static NSString *const kLockDirectory = @"/tmp";

@implementation XLXephyr

/* YES when the lock file names a process that still exists or cannot be
 * read as a pid; a server that crashed leaves its file behind. */
+ (BOOL)lockFileHolds:(NSString *)lockPath
{
    NSString *contents = [NSString stringWithContentsOfFile:lockPath
                                                   encoding:NSASCIIStringEncoding
                                                      error:NULL];
    if (contents == nil) {
        return YES;
    }
    NSString *trimmed = [contents stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger pid = [self integerFromDigits:trimmed];
    if (pid <= 0) {
        return YES;
    }
    // EPERM means the process exists but belongs to someone else
    return kill((pid_t)pid, 0) == 0 || errno != ESRCH;
}

/* Digits only, any size that fits; separate from dimensionFromString: so
 * that pids are not limited to the screen size range. */
+ (NSInteger)integerFromDigits:(NSString *)string
{
    NSUInteger length = [string length];
    if (length == 0 || length > 9) {
        return 0;
    }
    NSInteger value = 0;
    NSUInteger i;
    for (i = 0; i < length; i++) {
        unichar c = [string characterAtIndex:i];
        if (c < '0' || c > '9') {
            return 0;
        }
        value = value * 10 + (c - '0');
    }
    return value;
}

+ (NSInteger)firstFreeDisplayNumberWithSocketDirectory:(NSString *)socketDirectory
                                         lockDirectory:(NSString *)lockDirectory
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger n;
    for (n = XLMinimumDisplayNumber; n <= XLMaximumDisplayNumber; n++) {
        NSString *socket = [socketDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"X%ld", (long)n]];
        NSString *lock = [lockDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@".X%ld-lock", (long)n]];
        // A server that exited uncleanly may leave only the socket behind,
        // and it would refuse to start on top of it
        if ([fm fileExistsAtPath:socket]) {
            continue;
        }
        if ([fm fileExistsAtPath:lock] && [self lockFileHolds:lock]) {
            continue;
        }
        return n;
    }
    return -1;
}

+ (NSInteger)firstFreeDisplayNumber
{
    return [self firstFreeDisplayNumberWithSocketDirectory:kSocketDirectory
                                             lockDirectory:kLockDirectory];
}

+ (NSString *)xephyrPathInSearchPath:(NSString *)searchPath
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSEnumerator *dirs = [[searchPath componentsSeparatedByString:@":"] objectEnumerator];
    NSString *dir;
    while ((dir = [dirs nextObject]) != nil) {
        if ([dir length] == 0) {
            continue;
        }
        NSString *candidate = [dir stringByAppendingPathComponent:@"Xephyr"];
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory]
            && !isDirectory && [fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

+ (NSString *)xephyrPath
{
    return [self xephyrPathInSearchPath:
        [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"]];
}

+ (NSInteger)dimensionFromString:(NSString *)string
{
    NSString *trimmed = [string stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger value = [self integerFromDigits:trimmed];
    return value > XLMaximumDimension ? 0 : value;
}

+ (NSString *)validationErrorForWidth:(NSInteger)width
                               height:(NSInteger)height
                          screenCount:(NSInteger)screenCount
{
    if (width < XLMinimumDimension || width > XLMaximumDimension) {
        return [NSString stringWithFormat:
            NSLocalizedString(@"The width must be a number between %ld and %ld.", @""),
            (long)XLMinimumDimension, (long)XLMaximumDimension];
    }
    if (height < XLMinimumDimension || height > XLMaximumDimension) {
        return [NSString stringWithFormat:
            NSLocalizedString(@"The height must be a number between %ld and %ld.", @""),
            (long)XLMinimumDimension, (long)XLMaximumDimension];
    }
    if (screenCount < 1 || screenCount > XLMaximumScreenCount) {
        return [NSString stringWithFormat:
            NSLocalizedString(@"The number of screens must be between 1 and %ld.", @""),
            (long)XLMaximumScreenCount];
    }
    return nil;
}

+ (NSString *)displayStringForNumber:(NSInteger)number
{
    return [NSString stringWithFormat:@":%ld", (long)number];
}

+ (NSArray *)argumentsForDisplayNumber:(NSInteger)number
                                 width:(NSInteger)width
                                height:(NSInteger)height
                           screenCount:(NSInteger)screenCount
{
    NSString *display = [self displayStringForNumber:number];
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:
        display, @"-title", [@"Xephyr " stringByAppendingString:display], nil];
    NSString *size = [NSString stringWithFormat:@"%ldx%ld", (long)width, (long)height];
    NSInteger i;
    for (i = 0; i < screenCount; i++) {
        [arguments addObject:@"-screen"];
        [arguments addObject:size];
    }
    return arguments;
}

+ (NSDictionary *)environmentForDisplayNumber:(NSInteger)number
                              baseEnvironment:(NSDictionary *)base
{
    NSMutableDictionary *env = [[base mutableCopy] autorelease];
    // The cookie belongs to the host display; Xephyr accepts local clients
    [env removeObjectForKey:@"XAUTHORITY"];
    [env setObject:[self displayStringForNumber:number] forKey:@"DISPLAY"];
    return env;
}

+ (NSString *)socketPathForDisplayNumber:(NSInteger)number
{
    return [kSocketDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"X%ld", (long)number]];
}

@end
