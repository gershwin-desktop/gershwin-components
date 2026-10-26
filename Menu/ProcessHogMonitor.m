/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessHogMonitor.h"
#import "ProcessInfo.h"

static const double kCPUThresholdPercent = 95.0;
static const double kMemoryThresholdPercent = 50.0;

/* What the previous table said about one process.  The start token is part of
 * it because a pid is handed on to a new process after the old one ends. */
@interface ProcessHogReading : NSObject
@property (nonatomic) unsigned long long ticks;
@property (nonatomic) unsigned long long startToken;
@end

@implementation ProcessHogReading
@end

@implementation ProcessHogMonitor
{
    long _totalMemoryKB;
    long _ticksPerSecond;
    NSString *_currentUser;
    int _ownPid;
    NSMutableDictionary *_previousReadings;
    NSTimeInterval _previousTime;
}

+ (double)cpuThresholdPercent
{
    return kCPUThresholdPercent;
}

+ (double)memoryThresholdPercent
{
    return kMemoryThresholdPercent;
}

- (instancetype)initWithTotalMemoryKB:(long)totalMemoryKB
                       ticksPerSecond:(long)ticksPerSecond
                          currentUser:(NSString *)currentUser
                               ownPid:(int)ownPid
{
    self = [super init];
    if (self) {
        _totalMemoryKB = totalMemoryKB;
        _ticksPerSecond = ticksPerSecond;
        _currentUser = [currentUser copy];
        _ownPid = ownPid;
    }
    return self;
}

/* Only what the user may end without privilege, and never the panel's own
 * process or the init process. */
- (BOOL)mayOffer:(ProcessInfo *)info
{
    if ([info pid] <= 1 || [info pid] == _ownPid) {
        return NO;
    }
    if (![[info user] isEqualToString:_currentUser]) {
        return NO;
    }
    /* A zombie is already dead; killing it does nothing. */
    return !([[info state] hasPrefix:@"Z"]);
}

+ (NSString *)reasonForCPU:(double)cpu memory:(double)memory
{
    NSMutableArray *parts = [NSMutableArray array];
    if (cpu > kCPUThresholdPercent) {
        [parts addObject:[NSString stringWithFormat:@"%.0f%% CPU", cpu]];
    }
    if (memory > kMemoryThresholdPercent) {
        [parts addObject:[NSString stringWithFormat:@"%.0f%% memory", memory]];
    }
    return [parts componentsJoinedByString:@", "];
}

- (NSArray *)hogsAfterSample:(NSArray *)processes atTime:(NSTimeInterval)time
{
    NSTimeInterval elapsed = time - _previousTime;
    BOOL canMeasureCPU = (_previousReadings != nil && elapsed > 0 && _ticksPerSecond > 0);

    NSMutableDictionary *readings = [NSMutableDictionary dictionaryWithCapacity:[processes count]];
    NSMutableArray *hogs = [NSMutableArray array];
    for (ProcessInfo *info in processes) {
        if ([info usesCPUTicks]) {
            ProcessHogReading *reading = [[ProcessHogReading alloc] init];
            [reading setTicks:[info cpuTicks]];
            [reading setStartToken:[info startToken]];
            [readings setObject:reading forKey:[NSNumber numberWithInt:[info pid]]];
        }
        if (![self mayOffer:info]) {
            continue;
        }

        double cpu = 0.0;
        ProcessHogReading *before = [_previousReadings objectForKey:[NSNumber numberWithInt:[info pid]]];
        if (canMeasureCPU && [info usesCPUTicks] && before != nil
            && [before startToken] == [info startToken] && [info cpuTicks] >= [before ticks]) {
            double usedSeconds = (double)([info cpuTicks] - [before ticks]) / (double)_ticksPerSecond;
            cpu = usedSeconds / elapsed * 100.0;
        }
        double memory = (_totalMemoryKB > 0)
            ? (double)[info residentMemory] * 100.0 / (double)_totalMemoryKB : 0.0;

        NSString *reason = [ProcessHogMonitor reasonForCPU:cpu memory:memory];
        if ([reason length] == 0) {
            continue;
        }
        [hogs addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [info displayName], @"name",
            [NSNumber numberWithInt:[info pid]], @"pid",
            reason, @"reason",
            [NSNumber numberWithDouble:cpu], @"cpu",
            [NSNumber numberWithDouble:memory], @"memory", nil]];
    }

    _previousReadings = readings;
    _previousTime = time;
    return hogs;
}

+ (NSArray *)rowsForApplications:(NSArray *)applications hogs:(NSArray *)hogs
{
    NSMutableDictionary *reasonsByPid = [NSMutableDictionary dictionary];
    for (NSDictionary *hog in hogs) {
        [reasonsByPid setObject:[hog objectForKey:@"reason"] forKey:[hog objectForKey:@"pid"]];
    }

    NSMutableSet *applicationPids = [NSMutableSet set];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *application in applications) {
        NSNumber *pid = [application objectForKey:@"pid"];
        [applicationPids addObject:pid];
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [application objectForKey:@"name"], @"name",
            pid, @"pid",
            ([reasonsByPid objectForKey:pid] ?: @""), @"detail",
            [NSNumber numberWithBool:YES], @"application", nil]];
    }
    NSMutableArray *others = [NSMutableArray array];
    for (NSDictionary *hog in hogs) {
        if ([applicationPids containsObject:[hog objectForKey:@"pid"]]) {
            continue;
        }
        [others addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [hog objectForKey:@"name"], @"name",
            [hog objectForKey:@"pid"], @"pid",
            [hog objectForKey:@"reason"], @"detail",
            [NSNumber numberWithBool:NO], @"application", nil]];
    }

    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                             ascending:YES
                                                              selector:@selector(caseInsensitiveCompare:)];
    NSArray *sortedApplications = [rows sortedArrayUsingDescriptors:@[byName]];
    NSArray *sortedOthers = [others sortedArrayUsingDescriptors:@[byName]];
    return [sortedApplications arrayByAddingObjectsFromArray:sortedOthers];
}

@end
