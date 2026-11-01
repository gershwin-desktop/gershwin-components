/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorderFactory.h"
#import "PRPerfRecorder.h"
#import "PRHeaptrackRecorder.h"
#import "PRDTraceRecorder.h"

@implementation PRRecorderFactory

+ (Class)recorderClassForMode:(PRProfileMode)mode
{
#if defined(__linux__)
    return mode == PRProfileModeCPU ?
        [PRPerfRecorder class] : [PRHeaptrackRecorder class];
#elif defined(__FreeBSD__) || defined(__FreeBSD_kernel__) || defined(__NetBSD__)
    (void)mode;
    return [PRDTraceRecorder class];
#else
    /* OpenBSD has no DTrace; btrace(8) is the tool to grow a backend on. */
    (void)mode;
    return Nil;
#endif
}

+ (NSString *)toolNameForMode:(PRProfileMode)mode
{
    Class recorder = [self recorderClassForMode:mode];
    return recorder == Nil ? nil : [recorder toolName];
}

+ (NSString *)problemForMode:(PRProfileMode)mode
{
    Class recorder = [self recorderClassForMode:mode];
    if (recorder == Nil)
        return @"This system has no profiling backend yet. Only Linux "
               @"(perf, heaptrack) and the BSDs with DTrace are supported "
               @"so far.";

    if ([recorder toolPath] == nil)
        return [NSString stringWithFormat:
                @"%@ is not installed. Install the package \"%@\" to record "
                @"%@ profiles.",
                [recorder toolName], [recorder packageName],
                mode == PRProfileModeCPU ? @"CPU" : @"memory"];

    return nil;
}

@end
