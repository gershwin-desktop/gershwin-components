/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRProcessMonitor.h"
#import "PRProcessInfo.h"

#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>

#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__)
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/user.h>
#define PR_BSD_PROCESS_LIST 1
#elif defined(__OpenBSD__)
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/proc.h>
#define PR_BSD_PROCESS_LIST 1
#elif defined(__NetBSD__)
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/user.h>
#define PR_BSD_PROCESS_LIST 1
#endif

@implementation PRProcessMonitor

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _previousTicks = [[NSMutableDictionary alloc] init];
    _previousTime = [[NSMutableDictionary alloc] init];
    return self;
}

#if !defined(PR_BSD_PROCESS_LIST)

/* Field 14 and 15 of /proc/<pid>/stat are the ticks the process spent in
   user and system code. The name in field 2 is parenthesised and may
   contain spaces, so the fields are counted from the closing bracket. */
- (double)cpuPercentForProcess:(pid_t)pid
{
    NSString *stat = [NSString stringWithContentsOfFile:
                      [NSString stringWithFormat:@"/proc/%d/stat", pid]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (stat == nil)
        return 0;

    NSRange bracket = [stat rangeOfString:@") " options:NSBackwardsSearch];
    if (bracket.location == NSNotFound)
        return 0;

    NSArray *fields = [[stat substringFromIndex:NSMaxRange(bracket)]
                       componentsSeparatedByString:@" "];
    if ([fields count] < 13)
        return 0;

    double ticks = [[fields objectAtIndex:11] doubleValue] +
                   [[fields objectAtIndex:12] doubleValue];
    double now = [NSDate timeIntervalSinceReferenceDate];
    NSNumber *key = [NSNumber numberWithInt:pid];
    NSNumber *lastTicks = [_previousTicks objectForKey:key];
    NSNumber *lastTime = [_previousTime objectForKey:key];

    [_previousTicks setObject:[NSNumber numberWithDouble:ticks] forKey:key];
    [_previousTime setObject:[NSNumber numberWithDouble:now] forKey:key];

    if (lastTicks == nil || lastTime == nil)
        return 0;

    double elapsed = now - [lastTime doubleValue];
    if (elapsed <= 0)
        return 0;

    double hertz = (double)sysconf(_SC_CLK_TCK);
    return (ticks - [lastTicks doubleValue]) / hertz / elapsed * 100.0;
}

- (PRProcessInfo *)readLinuxProcess:(pid_t)pid
{
    NSString *statusPath = [NSString stringWithFormat:@"/proc/%d/status", pid];
    NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (status == nil)
        return nil;

    PRProcessInfo *info = [[PRProcessInfo alloc] init];
    [info setPid:pid];

    for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Name:"]) {
            [info setName:[[line substringFromIndex:5]
                           stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]]];
        } else if ([line hasPrefix:@"VmRSS:"]) {
            [info setRssBytes:(unsigned long long)
             [[line substringFromIndex:6] longLongValue] * 1024ULL];
        } else if ([line hasPrefix:@"VmSize:"]) {
            [info setVirtualBytes:(unsigned long long)
             [[line substringFromIndex:7] longLongValue] * 1024ULL];
        } else if ([line hasPrefix:@"Uid:"]) {
            [info setUser:(uid_t)[[line substringFromIndex:4] intValue]];
        }
    }

    if ([info name] == nil)
        return nil;

    NSString *cmdline = [NSString stringWithContentsOfFile:
                         [NSString stringWithFormat:@"/proc/%d/cmdline", pid]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if ([cmdline length] > 0)
        [info setCommand:[[cmdline stringByReplacingOccurrencesOfString:@"\0"
                                                             withString:@" "]
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]]];
    else
        [info setCommand:[info name]];

    NSString *executable = [[NSFileManager defaultManager]
                            pathContentOfSymbolicLinkAtPath:
                            [NSString stringWithFormat:@"/proc/%d/exe", pid]];
    [info setExecutablePath:executable];
    [info setCpuPercent:[self cpuPercentForProcess:pid]];
    return info;
}

- (NSArray *)processes
{
    NSMutableArray *result = [NSMutableArray array];
    NSArray *entries = [[NSFileManager defaultManager]
                        contentsOfDirectoryAtPath:@"/proc" error:NULL];

    for (NSString *entry in entries) {
        int pid = [entry intValue];
        if (pid <= 0)
            continue;
        PRProcessInfo *info = [self readLinuxProcess:(pid_t)pid];
        /* Kernel threads have no address space to profile. */
        if (info == nil || [info virtualBytes] == 0)
            continue;
        [result addObject:info];
    }
    return result;
}

- (PRProcessInfo *)processWithIdentifier:(pid_t)pid
{
    return [self readLinuxProcess:pid];
}

#else

- (PRProcessInfo *)infoFromKernelProcess:(struct kinfo_proc *)process
{
    PRProcessInfo *info = [[PRProcessInfo alloc] init];
#if defined(__OpenBSD__)
    [info setPid:process->p_pid];
    [info setName:[NSString stringWithUTF8String:process->p_comm]];
    [info setCommand:[NSString stringWithUTF8String:process->p_comm]];
    [info setUser:(uid_t)process->p_uid];
    [info setRssBytes:(unsigned long long)process->p_vm_rssize *
     (unsigned long long)getpagesize()];
    [info setVirtualBytes:((unsigned long long)process->p_vm_tsize +
                           process->p_vm_dsize + process->p_vm_ssize) *
     (unsigned long long)getpagesize()];
    [info setCpuPercent:(double)process->p_pctcpu / (double)FSCALE * 100.0];
#else
    [info setPid:process->ki_pid];
    [info setName:[NSString stringWithUTF8String:process->ki_comm]];
    [info setCommand:[NSString stringWithUTF8String:process->ki_comm]];
    [info setUser:(uid_t)process->ki_uid];
    [info setRssBytes:(unsigned long long)process->ki_rssize *
     (unsigned long long)getpagesize()];
    [info setVirtualBytes:(unsigned long long)process->ki_size];
    [info setCpuPercent:(double)process->ki_pctcpu / (double)FSCALE * 100.0];
#endif
    return info;
}

- (NSArray *)processes
{
    NSMutableArray *result = [NSMutableArray array];
#if defined(__OpenBSD__)
    int mib[6] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0,
                   sizeof(struct kinfo_proc), 0 };
    size_t mibSize = 6;
#else
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PROC, 0 };
    size_t mibSize = 4;
#endif
    size_t size = 0;

    if (sysctl(mib, mibSize, NULL, &size, NULL, 0) != 0)
        return result;

#if defined(__OpenBSD__)
    mib[5] = (int)(size / sizeof(struct kinfo_proc));
#endif

    struct kinfo_proc *processes = malloc(size);
    if (processes == NULL)
        return result;

    if (sysctl(mib, mibSize, processes, &size, NULL, 0) != 0) {
        free(processes);
        return result;
    }

    size_t count = size / sizeof(*processes);
    for (size_t i = 0; i < count; i++)
        [result addObject:[self infoFromKernelProcess:&processes[i]]];

    free(processes);
    return result;
}

- (PRProcessInfo *)processWithIdentifier:(pid_t)pid
{
#if defined(__OpenBSD__)
    int mib[6] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid,
                   sizeof(struct kinfo_proc), 1 };
    size_t mibSize = 6;
#else
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    size_t mibSize = 4;
#endif
    size_t size = 0;

    if (sysctl(mib, mibSize, NULL, &size, NULL, 0) != 0)
        return nil;

    struct kinfo_proc *process = malloc(size);
    if (process == NULL)
        return nil;

    if (sysctl(mib, mibSize, process, &size, NULL, 0) != 0) {
        free(process);
        return nil;
    }

    PRProcessInfo *info = [self infoFromKernelProcess:process];
    free(process);
    return info;
}

#endif

@end
