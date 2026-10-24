/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRPerfRecorder.h"
#import "PRRecorderPrivate.h"
#import "PRPrivilegedTask.h"
#import "PRProfile.h"
#import "PRStackParser.h"

@implementation PRPerfRecorder

+ (NSString *)toolName
{
    return @"perf";
}

+ (BOOL)supportsMode:(PRProfileMode)mode
{
    return mode == PRProfileModeCPU;
}

+ (NSString *)packageName
{
    return @"linux-perf";
}

+ (int)perfEventParanoid
{
    NSString *value = [NSString stringWithContentsOfFile:
                       @"/proc/sys/kernel/perf_event_paranoid"
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    if (value == nil)
        return -1;
    return [value intValue];
}

+ (NSString *)warningForRequest:(PRRecordRequest *)request
{
    (void)request;
    return nil;
}

- (NSString *)callGraphArgument
{
    switch ([_request callGraph]) {
        case PRCallGraphFramePointer: return @"fp";
        case PRCallGraphLastBranch: return @"lbr";
        case PRCallGraphDwarf:
        default: return @"dwarf";
    }
}

- (BOOL)recordNeedsElevation
{
    /* Anything above 1 forbids sampling even our own processes, and
       attaching to a process of another user always needs root. */
    return [PRPerfRecorder perfEventParanoid] > 1 || [_request isAttach];
}

- (BOOL)launchRecordTaskWithError:(NSError **)error
{
    NSString *perf = [PRPerfRecorder toolPath];
    if (perf == nil)
        return [self failWithMessage:
                @"perf is not installed. Install it to record CPU profiles."
                               error:error];

    BOOL elevated = [self recordNeedsElevation];
    if (elevated && ![PRPrivilegedTask isElevationAvailable])
        return [self failWithMessage:[PRPrivilegedTask elevationProblem]
                               error:error];

    _dataPath = [_workDirectory stringByAppendingPathComponent:@"perf.data"];

    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:
                                 @"record",
                                 @"-F", [NSString stringWithFormat:@"%lu",
                                         (unsigned long)[_request frequency]],
                                 @"--call-graph", [self callGraphArgument],
                                 @"-o", _dataPath, nil];

    if ([_request isAttach]) {
        [arguments addObject:@"-p"];
        [arguments addObject:[NSString stringWithFormat:@"%d", [_request pid]]];
    } else {
        [arguments addObject:@"--"];
        [arguments addObject:[_request launchPath]];
        [arguments addObjectsFromArray:[_request arguments]];
    }

    NSTask *task = [PRPrivilegedTask taskForTool:perf
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
                [NSString stringWithFormat:@"Could not start perf: %@",
                 [exception reason]]
                               error:error];
    }

    _recordTask = task;
    return YES;
}

- (PRProfile *)analyzeWithError:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:_dataPath]) {
        NSString *log = [self toolLog];
        [self failWithMessage:
         [NSString stringWithFormat:@"perf wrote no data.%@%@",
          [log length] ? @"\n\n" : @"", log]
                        error:error];
        return nil;
    }

    PRProfile *profile = [[PRProfile alloc] init];
    [profile setCostUnit:PRCostUnitSamples];
    [profile setRecordedAt:[NSDate date]];
    [profile setToolDescription:@"perf"];
    [profile setTitle:[_request targetName]];
    [profile setCommand:[_request isAttach] ?
     [NSString stringWithFormat:@"attached to process %d", [_request pid]] :
     [_request launchPath]];

    PRPerfScriptParser *parser = [[PRPerfScriptParser alloc]
                                  initWithProfile:profile];
    NSArray *arguments = @[@"script", @"-i", _dataPath,
                           @"-F", @"comm,pid,tid,time,event,ip,sym,dso"];

    if (![self runTool:[PRPerfRecorder toolPath]
             arguments:arguments
              elevated:NO
           lineHandler:^(NSString *line) { [parser parseLine:line]; }
                 error:error])
        return nil;

    [parser finish];

    if ([profile sampleCount] == 0) {
        [self failWithMessage:
         @"perf recorded no samples. The program may not have used any CPU "
         @"time while it was being watched."
                        error:error];
        return nil;
    }

    [profile setSummaryText:[self summaryForProfile:profile]];
    return profile;
}

- (NSString *)summaryForProfile:(PRProfile *)profile
{
    double span = [profile endTime] - [profile startTime];
    NSMutableString *text = [NSMutableString string];

    [text appendFormat:@"Tool:        perf, %@ call graphs at %lu Hz\n",
     [self callGraphArgument], (unsigned long)[_request frequency]];
    [text appendFormat:@"Target:      %@\n", [profile command]];
    [text appendFormat:@"Samples:     %lu\n", (unsigned long)[profile sampleCount]];
    [text appendFormat:@"Duration:    %.2f s\n", span];
    [text appendFormat:@"Threads:     %lu\n", (unsigned long)[[profile threads] count]];
    [text appendFormat:@"Symbols:     %lu distinct functions\n",
     (unsigned long)[profile symbolCount]];

    if (span > 0)
        [text appendFormat:@"\nOne sample stands for about %.1f ms of CPU time.\n",
         1000.0 / (double)[_request frequency]];

    NSString *log = [self toolLog];
    if ([log length] > 0)
        [text appendFormat:@"\nperf reported:\n%@\n", log];

    return text;
}

@end
