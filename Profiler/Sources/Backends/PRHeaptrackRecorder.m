/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRHeaptrackRecorder.h"
#import "PRRecorderPrivate.h"
#import "PRPrivilegedTask.h"
#import "PRProfile.h"
#import "PRStackParser.h"

@implementation PRHeaptrackRecorder
{
    PRMemoryCost _cost;
    NSMutableString *_printSummary;
}

+ (NSString *)toolName
{
    return @"heaptrack";
}

+ (BOOL)supportsMode:(PRProfileMode)mode
{
    return mode == PRProfileModeMemory;
}

+ (NSString *)packageName
{
    return @"heaptrack";
}

+ (NSString *)warningForRequest:(PRRecordRequest *)request
{
    if (![request isAttach])
        return nil;
    return @"heaptrack has to inject itself into a process that is already "
           @"running, which can make that process crash, especially once the "
           @"recording ends. Starting the program from here instead is safe.";
}

- (NSString *)costArgument
{
    switch (_cost) {
        case PRMemoryCostLeaked: return @"leaked";
        case PRMemoryCostAllocations: return @"allocations";
        case PRMemoryCostTemporary: return @"temporary";
        case PRMemoryCostPeak:
        default: return @"peak";
    }
}

- (PRCostUnit)costUnit
{
    if (_cost == PRMemoryCostAllocations || _cost == PRMemoryCostTemporary)
        return PRCostUnitAllocations;
    return PRCostUnitBytes;
}

- (BOOL)recordNeedsElevation
{
    /* Injecting into a running process needs ptrace rights that a normal
       user does not have for a process it did not start. */
    return [_request isAttach];
}

- (BOOL)launchRecordTaskWithError:(NSError **)error
{
    NSString *heaptrack = [PRHeaptrackRecorder toolPath];
    if (heaptrack == nil)
        return [self failWithMessage:
                @"heaptrack is not installed. Install it to record memory "
                @"profiles." error:error];

    _cost = [_request memoryCost];

    BOOL elevated = [self recordNeedsElevation];
    if (elevated && ![PRPrivilegedTask isElevationAvailable])
        return [self failWithMessage:[PRPrivilegedTask elevationProblem]
                               error:error];

    NSString *stem = [_workDirectory stringByAppendingPathComponent:@"heaptrack"];
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"-o", stem, nil];

    if ([_request isAttach]) {
        [arguments addObject:@"-p"];
        [arguments addObject:[NSString stringWithFormat:@"%d", [_request pid]]];
    } else {
        [arguments addObject:[_request launchPath]];
        [arguments addObjectsFromArray:[_request arguments]];
    }

    NSTask *task = [PRPrivilegedTask taskForTool:heaptrack
                                       arguments:arguments
                                        elevated:elevated];
    if (task == nil)
        return [self failWithMessage:@"sudo is not available." error:error];

    [task setStandardOutput:[self logFileHandle]];
    [task setStandardError:[self logFileHandle]];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return [self failWithMessage:
                [NSString stringWithFormat:@"Could not start heaptrack: %@",
                 [exception reason]] error:error];
    }

    _recordTask = task;
    return YES;
}

/* heaptrack appends the process id and a compression suffix to the name it
   was given, so the file it actually wrote has to be looked up. */
- (NSString *)recordedDataPath
{
    NSArray *entries = [[NSFileManager defaultManager]
                        contentsOfDirectoryAtPath:_workDirectory error:NULL];
    for (NSString *entry in entries)
        if ([entry hasPrefix:@"heaptrack"] && ![entry hasSuffix:@".log"])
            return [_workDirectory stringByAppendingPathComponent:entry];
    return nil;
}

- (BOOL)reanalyzeWithMemoryCost:(PRMemoryCost)cost
{
    if (_analyzing || [self recordedDataPath] == nil)
        return NO;
    _cost = cost;
    [self beginAnalysis];
    return YES;
}

- (PRProfile *)analyzeWithError:(NSError **)error
{
    NSString *data = [self recordedDataPath];
    if (data == nil) {
        NSString *log = [self toolLog];
        [self failWithMessage:
         [NSString stringWithFormat:@"heaptrack wrote no data.%@%@",
          [log length] ? @"\n\n" : @"", log] error:error];
        return nil;
    }
    _dataPath = data;

    NSString *print = [PRToolLocator pathForTool:@"heaptrack_print"];
    if (print == nil) {
        [self failWithMessage:
         @"heaptrack_print is not installed, so the recording cannot be read."
                        error:error];
        return nil;
    }

    NSString *folded = [_workDirectory stringByAppendingPathComponent:@"folded.txt"];
    NSString *massif = [_workDirectory stringByAppendingPathComponent:@"massif.out"];
    [[NSFileManager defaultManager] removeItemAtPath:folded error:NULL];

    _printSummary = [NSMutableString string];
    NSArray *arguments = @[@"-f", data,
                           @"-F", folded,
                           @"--flamegraph-cost-type", [self costArgument],
                           @"-M", massif,
                           @"-p", @"0", @"-a", @"0", @"-T", @"0"];

    if (![self runTool:print
             arguments:arguments
              elevated:NO
           lineHandler:^(NSString *line) {
               NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
               if ([trimmed length] > 0 && ![trimmed hasPrefix:@"reading file"] &&
                   ![trimmed hasPrefix:@"finished reading"])
                   [_printSummary appendFormat:@"%@\n", trimmed];
           }
                 error:error])
        return nil;

    NSString *foldedText = [NSString stringWithContentsOfFile:folded
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
    if (foldedText == nil) {
        [self failWithMessage:@"heaptrack_print produced no stacks." error:error];
        return nil;
    }

    PRProfile *profile = [[PRProfile alloc] init];
    [profile setCostUnit:[self costUnit]];
    [profile setRecordedAt:[NSDate date]];
    [profile setToolDescription:[NSString stringWithFormat:@"heaptrack (%@)",
                                 [self costArgument]]];
    [profile setTitle:[_request targetName]];
    [profile setCommand:[_request isAttach] ?
     [NSString stringWithFormat:@"attached to process %d", [_request pid]] :
     [_request launchPath]];

    PRFoldedStackParser *parser = [[PRFoldedStackParser alloc]
                                   initWithProfile:profile];
    [parser parseString:foldedText];

    if ([profile sampleCount] == 0) {
        [self failWithMessage:
         @"The recording contains no allocations of this kind." error:error];
        return nil;
    }

    [profile setMemoryTimeline:[self timelineFromMassifFile:massif]];
    [profile setSummaryText:[NSString stringWithFormat:
                             @"Tool:        heaptrack, %@ cost\n"
                             @"Target:      %@\n"
                             @"Call sites:  %lu\n\n%@",
                             [self costArgument], [profile command],
                             (unsigned long)[profile sampleCount],
                             _printSummary]];
    return profile;
}

/* The allocation stacks carry no time of their own, so the consumption
   curve comes from the massif snapshots heaptrack_print can write. */
- (NSArray *)timelineFromMassifFile:(NSString *)path
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text == nil)
        return nil;

    NSMutableArray *points = [NSMutableArray array];
    double time = 0;

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"time="]) {
            time = [[line substringFromIndex:5] doubleValue];
        } else if ([line hasPrefix:@"mem_heap_B="]) {
            double bytes = [[line substringFromIndex:11] doubleValue];
            [points addObject:@{@"time": [NSNumber numberWithDouble:time],
                                @"value": [NSNumber numberWithDouble:bytes]}];
        }
    }
    return points;
}

@end
