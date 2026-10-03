/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashPlatform.h"
#import "GSCrashConstants.h"
#import <sys/resource.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#import <string.h>

static NSString *GSCrashSavedCorePatternPath(void)
{
    return [GSCrashBaseDirectory() stringByAppendingPathComponent:@"core_pattern.save"];
}

static NSString *GSCrashReadProc(NSString *path)
{
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil)
        return nil;
    NSData *d = [fh readDataToEndOfFile];
    if (d == nil)
        return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@interface GSCrashPlatformLinux : NSObject <GSCrashPlatform>
@end

@implementation GSCrashPlatformLinux

- (NSString *)platformName
{
    return @"Linux";
}

- (BOOL)isCoreDumpingEnabled
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_CORE, &rl) != 0)
        return NO;
    return rl.rlim_cur > 0;
}

- (NSString *)coreDumpLocation
{
    NSString *pat = GSCrashReadProc(@"/proc/sys/kernel/core_pattern");
    if (pat == nil)
        return nil;
    if ([pat hasPrefix:@"|"])
        return nil; /* piped to a collector */
    /* pattern may contain % specifiers; take the directory part */
    NSString *dir = [pat stringByDeletingLastPathComponent];
    if ([dir length] == 0 || [pat isEqualToString:[pat lastPathComponent]])
        return [NSHomeDirectory() stringByAppendingPathComponent:@"core"];
    return dir;
}

- (NSString *)existingCrashCollector
{
    NSString *pat = GSCrashReadProc(@"/proc/sys/kernel/core_pattern");
    if (pat == nil)
        return @"none";
    if ([pat hasPrefix:@"|"])
    {
        NSString *prog = [pat substringFromIndex:1];
        prog = [prog stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *parts = [prog componentsSeparatedByString:@" "];
        NSString *name = [[parts firstObject] lastPathComponent];
        if ([name containsString:@"systemd-coredump"])
            return @"systemd-coredump";
        if ([name containsString:@"abrt"])
            return @"abrt";
        return @"core_pattern-pipe";
    }
    return @"kernel";
}

- (BOOL)saveCoreConfiguration:(NSError **)error
{
    NSString *pat = GSCrashReadProc(@"/proc/sys/kernel/core_pattern");
    if (pat == nil)
        return YES; /* nothing to save */
    return [pat writeToFile:GSCrashSavedCorePatternPath()
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:error];
}

- (BOOL)restoreCoreConfiguration:(NSError **)error
{
    NSString *saved = [NSString stringWithContentsOfFile:GSCrashSavedCorePatternPath()
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (saved == nil)
        return YES; /* nothing was saved */
    NSError *lerr = nil;
    if (![saved writeToFile:@"/proc/sys/kernel/core_pattern"
                 atomically:NO
                   encoding:NSUTF8StringEncoding
                      error:&lerr])
    {
        if (error)
            *error = [NSError errorWithDomain:GSCrashReverseDNS
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                         [NSString stringWithFormat:
                                          @"Could not restore previous core_pattern (root required): %@", lerr] }];
        return NO;
    }
    return YES;
}

- (BOOL)configureCoreDumpsToDirectory:(NSString *)directory error:(NSError **)error
{
    NSString *collector = [self existingCrashCollector];
    if ([collector isEqualToString:@"systemd-coredump"] ||
        [collector isEqualToString:@"abrt"] ||
        [collector isEqualToString:@"core_pattern-pipe"])
    {
        if (error)
            *error = [NSError errorWithDomain:GSCrashReverseDNS
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                         [NSString stringWithFormat:
                                          @"An existing crash collector (%@) owns core handling. "
                                          @"CrashReporter will not overwrite it without consent.", collector] }];
        return NO;
    }

    [self saveCoreConfiguration:nil];

    /* Raise our own core limit so child processes we launch can dump cores. */
    struct rlimit rl;
    rl.rlim_cur = RLIM_INFINITY;
    rl.rlim_max = RLIM_INFINITY;
    setrlimit(RLIMIT_CORE, &rl);

    /*
     * Configure a core_pattern that writes uniquely-named cores into the crash
     * base directory. We never touch an administrator pattern that we did not
     * save ourselves. Writing /proc/sys/kernel/core_pattern requires root.
     */
    NSString *pattern = [NSString stringWithFormat:@"%@/core.%%e.%%p",
                         [directory stringByDeletingLastPathComponent]];
    NSError *lerr = nil;
    if (![pattern writeToFile:@"/proc/sys/kernel/core_pattern"
                   atomically:NO
                     encoding:NSUTF8StringEncoding
                        error:&lerr])
    {
        if (error)
            *error = [NSError errorWithDomain:GSCrashReverseDNS
                                         code:3
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                         [NSString stringWithFormat:
                                          @"Core pattern could not be set (root required). "
                                          @"CrashReporter will rely on application markers instead. %@", lerr] }];
        return NO;
    }
    return YES;
}

- (BOOL)installCrashMonitor:(NSError **)error
{
    return YES; /* directory watching is performed by the daemon */
}

- (BOOL)startCrashService:(NSError **)error
{
    return YES;
}

@end
