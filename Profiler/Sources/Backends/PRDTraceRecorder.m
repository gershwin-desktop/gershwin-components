/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRDTraceRecorder.h"
#import "PRRecorderPrivate.h"
#import "PRPrivilegedTask.h"
#import "PRProfile.h"
#import "PRStackParser.h"

@implementation PRDTraceRecorder

+ (NSString *)toolName
{
    return @"dtrace";
}

+ (BOOL)supportsMode:(PRProfileMode)mode
{
    (void)mode;
    return YES;
}

+ (NSString *)packageName
{
    return @"dtrace";
}

+ (NSString *)warningForRequest:(PRRecordRequest *)request
{
    if ([request mode] == PRProfileModeMemory)
        return @"Tracing every allocation call slows the program down "
               @"noticeably. Record only as long as you need.";
    return nil;
}

- (BOOL)recordNeedsElevation
{
    return YES;
}

- (NSString *)scriptForRequest
{
    NSMutableString *script = [NSMutableString string];
    [script appendString:@"#pragma D option quiet\n"];
    [script appendString:@"#pragma D option ustackframes=64\n"];
    [script appendString:@"#pragma D option bufsize=16m\n"];

    if ([_request mode] == PRProfileModeCPU) {
        [script appendFormat:
         @"profile-%lu /pid == $target/ { @stacks[ustack()] = count(); }\n",
         (unsigned long)[_request frequency]];
    } else {
        /* Weighing each call by its requested size gives the same "bytes
           per call path" that the Linux backend reports. */
        [script appendString:
         @"pid$target::malloc:entry { @stacks[ustack()] = sum(arg0); }\n"
         @"pid$target::calloc:entry { @stacks[ustack()] = sum(arg0 * arg1); }\n"
         @"pid$target::realloc:entry { @stacks[ustack()] = sum(arg1); }\n"];
    }

    [script appendString:@"END { printa(\"%k%@d\\n\", @stacks); }\n"];
    return script;
}

- (BOOL)launchRecordTaskWithError:(NSError **)error
{
    NSString *dtrace = [PRDTraceRecorder toolPath];
    if (dtrace == nil)
        return [self failWithMessage:
                @"dtrace is not installed. Install it to record profiles."
                               error:error];

    if (![PRPrivilegedTask isElevationAvailable])
        return [self failWithMessage:[PRPrivilegedTask elevationProblem]
                               error:error];

    NSString *scriptPath = [_workDirectory stringByAppendingPathComponent:@"probe.d"];
    if (![[self scriptForRequest] writeToFile:scriptPath
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:error])
        return NO;

    _dataPath = [_workDirectory stringByAppendingPathComponent:@"stacks.txt"];
    [[NSFileManager defaultManager] createFileAtPath:_dataPath
                                            contents:[NSData data]
                                          attributes:nil];

    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:
                                 @"-s", scriptPath, nil];
    if ([_request isAttach]) {
        [arguments addObject:@"-p"];
        [arguments addObject:[NSString stringWithFormat:@"%d", [_request pid]]];
    } else {
        NSMutableArray *words = [NSMutableArray arrayWithObject:[_request launchPath]];
        [words addObjectsFromArray:[_request arguments]];
        [arguments addObject:@"-c"];
        [arguments addObject:[words componentsJoinedByString:@" "]];
    }

    NSTask *task = [PRPrivilegedTask taskForTool:dtrace
                                       arguments:arguments
                                        elevated:YES];
    if (task == nil)
        return [self failWithMessage:@"sudo is not available." error:error];

    /* DTrace prints the aggregation itself, so its output is the data. */
    [task setStandardOutput:[NSFileHandle fileHandleForWritingAtPath:_dataPath]];
    [task setStandardError:[self logFileHandle]];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return [self failWithMessage:
                [NSString stringWithFormat:@"Could not start dtrace: %@",
                 [exception reason]] error:error];
    }

    _recordTask = task;
    return YES;
}

- (PRProfile *)analyzeWithError:(NSError **)error
{
    NSString *text = [NSString stringWithContentsOfFile:_dataPath
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if ([text length] == 0) {
        NSString *log = [self toolLog];
        [self failWithMessage:
         [NSString stringWithFormat:@"dtrace recorded nothing.%@%@",
          [log length] ? @"\n\n" : @"", log] error:error];
        return nil;
    }

    PRProfile *profile = [[PRProfile alloc] init];
    [profile setCostUnit:[_request mode] == PRProfileModeCPU ?
     PRCostUnitSamples : PRCostUnitBytes];
    [profile setRecordedAt:[NSDate date]];
    [profile setToolDescription:@"dtrace"];
    [profile setTitle:[_request targetName]];
    [profile setCommand:[_request isAttach] ?
     [NSString stringWithFormat:@"attached to process %d", [_request pid]] :
     [_request launchPath]];

    PRDTraceStackParser *parser = [[PRDTraceStackParser alloc]
                                   initWithProfile:profile];
    [parser parseString:text];

    if ([profile sampleCount] == 0) {
        [self failWithMessage:@"dtrace collected no stacks." error:error];
        return nil;
    }

    [profile setSummaryText:[NSString stringWithFormat:
                             @"Tool:        dtrace\n"
                             @"Target:      %@\n"
                             @"Call paths:  %lu\n"
                             @"Symbols:     %lu distinct functions\n\n%@",
                             [profile command],
                             (unsigned long)[profile sampleCount],
                             (unsigned long)[profile symbolCount],
                             [self toolLog]]];
    return profile;
}

@end
