/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The profiler without its windows: the same readers, parsers and counting
   the application uses, for a terminal, a script or a test that has to fail
   when a leak comes back. Everything it prints goes to standard output,
   everything that went wrong goes to standard error with a status of 1, and
   --json turns every answer into machine readable form. */

#import <Foundation/Foundation.h>
#import "PRFormat.h"
#import "PRProfile.h"
#import "PRCallNode.h"
#import "PRSymbol.h"
#import "PRStackParser.h"
#import "PRMemoryMap.h"
#import "PRMemoryMapReader.h"
#import "PRProcessMonitor.h"
#import "PRProcessInfo.h"
#import "PRCensus.h"
#import "PRCensusClient.h"
#import "PRAllocationTrace.h"
#import "PRRecorderFactory.h"
#import "PRPrivilegedTask.h"

static BOOL gJSON = NO;

static void Say(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stdout, "%s\n", [line UTF8String]);
}

static int Fail(NSString *message)
{
    fprintf(stderr, "profiler: %s\n", [message UTF8String]);
    return 1;
}

static int PrintJSON(id object)
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (data == nil)
        return Fail([error localizedDescription]);
    fwrite([data bytes], 1, [data length], stdout);
    fputc('\n', stdout);
    return 0;
}

/* Options are read once, so a command can be written as if it had them. */
static NSString *Option(NSArray *arguments, NSString *name, NSString *fallback)
{
    NSUInteger index = [arguments indexOfObject:name];
    if (index == NSNotFound || index + 1 >= [arguments count])
        return fallback;
    return [arguments objectAtIndex:index + 1];
}

static BOOL Flag(NSArray *arguments, NSString *name)
{
    return [arguments indexOfObject:name] != NSNotFound;
}

/* Everything that is not an option, in order. */
static NSArray *Words(NSArray *arguments)
{
    NSMutableArray *words = [NSMutableArray array];
    NSSet *takesValue = [NSSet setWithObjects:@"--by", @"--for", @"--top",
                         @"--pid", @"--rate", @"--cost", @"--min", @"-o", nil];
    BOOL skip = NO;

    for (NSString *argument in arguments) {
        if (skip) { skip = NO; continue; }
        if ([argument hasPrefix:@"--"]) {
            skip = [takesValue containsObject:argument];
            continue;
        }
        [words addObject:argument];
    }
    return words;
}

/* profiler memory */

static NSDictionary *RegionAsDictionary(PRMemoryRegion *region, double total)
{
    return @{@"name": [region name] ? [region name] : @"",
             @"detail": [region path] ? [region path] : @"",
             @"kind": PRMemoryKindName([region kind]),
             @"resident": [NSNumber numberWithUnsignedLongLong:[region resident]],
             @"private": [NSNumber numberWithUnsignedLongLong:[region privateBytes]],
             @"swap": [NSNumber numberWithUnsignedLongLong:[region swap]],
             @"mapped": [NSNumber numberWithUnsignedLongLong:[region mapped]],
             @"mappings": [NSNumber numberWithUnsignedInteger:[region count]],
             @"share": [NSNumber numberWithDouble:
                        total > 0 ? (double)[region resident] / total : 0.0]};
}

static int MemoryOfProcess(pid_t pid, NSString *by)
{
    NSError *error = nil;
    PRMemoryMap *map = [PRMemoryMapReader mapForProcess:pid error:&error];
    if (map == nil)
        return Fail([error localizedDescription]);

    BOOL byFile = [by isEqualToString:@"file"];
    NSArray *rows = byFile ? [map regionsByName] : [map regionsByKind];
    double total = (double)[map resident];

    if (gJSON) {
        NSMutableArray *list = [NSMutableArray array];
        for (PRMemoryRegion *region in rows)
            [list addObject:RegionAsDictionary(region, total)];
        return PrintJSON(@{@"pid": [NSNumber numberWithInt:(int)pid],
                           @"resident": [NSNumber numberWithUnsignedLongLong:[map resident]],
                           @"private": [NSNumber numberWithUnsignedLongLong:[map privateBytes]],
                           @"swap": [NSNumber numberWithUnsignedLongLong:[map swap]],
                           @"mapped": [NSNumber numberWithUnsignedLongLong:[map mapped]],
                           @"by": byFile ? @"file" : @"kind",
                           @"rows": list});
    }

    Say(@"%@ in RAM, %@ of it its own%@",
        [PRFormat stringForBytes:(double)[map resident]],
        [PRFormat stringForBytes:(double)[map privateBytes]],
        [map swap] > 0 ? [NSString stringWithFormat:@", %@ in swap",
                          [PRFormat stringForBytes:(double)[map swap]]] : @"");
    Say(@"");
    Say(@"%10s %7s %10s %8s  %@", "IN RAM", "SHARE", "ITS OWN", "IN SWAP",
        byFile ? @"FILE OR MAPPING" : @"WHAT IT IS USED FOR");

    for (PRMemoryRegion *region in rows) {
        Say(@"%10s %7s %10s %8s  %@",
            [[PRFormat stringForBytes:(double)[region resident]] UTF8String],
            [[PRFormat percentOf:(double)[region resident] total:total] UTF8String],
            [[PRFormat stringForBytes:(double)[region privateBytes]] UTF8String],
            [region swap] > 0 ?
                [[PRFormat stringForBytes:(double)[region swap]] UTF8String] : "",
            [region name]);
    }
    if (![PRMemoryMapReader reportsResidentMemoryPerMapping])
        Say(@"\nThis system reports only the memory claimed, not what is in RAM.");
    return 0;
}

static int MemoryOfEveryProcess(void)
{
    PRProcessMonitor *monitor = [[PRProcessMonitor alloc] init];
    NSArray *processes = [[monitor processes] sortedArrayUsingComparator:
                          ^NSComparisonResult(PRProcessInfo *a, PRProcessInfo *b) {
        if ([a rssBytes] > [b rssBytes]) return NSOrderedAscending;
        if ([a rssBytes] < [b rssBytes]) return NSOrderedDescending;
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];

    if (gJSON) {
        NSMutableArray *list = [NSMutableArray array];
        for (PRProcessInfo *process in processes)
            [list addObject:@{@"pid": [NSNumber numberWithInt:[process pid]],
                              @"name": [process name] ? [process name] : @"",
                              @"resident": [NSNumber numberWithUnsignedLongLong:
                                            [process rssBytes]],
                              @"virtual": [NSNumber numberWithUnsignedLongLong:
                                           [process virtualBytes]]}];
        return PrintJSON(@{@"processes": list});
    }

    Say(@"%10s %7s  %@", "IN RAM", "PID", @"PROGRAM");
    for (PRProcessInfo *process in processes)
        Say(@"%10s %7d  %@",
            [[PRFormat stringForBytes:(double)[process rssBytes]] UTF8String],
            [process pid], [process name]);
    return 0;
}

/* profiler objects */

static int WatchObjects(NSArray *words, NSTimeInterval seconds, NSUInteger top)
{
    if ([words count] < 2)
        return Fail(@"name the program to watch: profiler objects <program>");

    NSString *program = [words objectAtIndex:1];
    NSArray *arguments = [words count] > 2 ?
        [words subarrayWithRange:NSMakeRange(2, [words count] - 2)] : @[];

    PRCensusClient *client = [[PRCensusClient alloc] init];
    NSError *error = nil;
    if (![client startProgram:program arguments:arguments error:&error])
        return Fail([error localizedDescription]);

    /* The program needs a moment before it can answer at all. */
    PRCensusSnapshot *first = nil;
    for (int attempt = 0; attempt < 20 && first == nil; attempt++) {
        [NSThread sleepForTimeInterval:0.5];
        first = [client takeSnapshotWithError:&error];
    }
    if (first == nil) {
        [client stop];
        return Fail([error localizedDescription]);
    }

    [NSThread sleepForTimeInterval:seconds];

    PRCensusSnapshot *second = [client takeSnapshotWithError:&error];
    if (second == nil) {
        [client stop];
        return Fail([error localizedDescription]);
    }

    NSArray *rows = [second rowsComparedWith:first];
    NSInteger grown = [second liveTotal] - [first liveTotal];
    [client stop];

    if (gJSON) {
        NSMutableArray *list = [NSMutableArray array];
        for (PRCensusRow *row in rows) {
            if ([list count] >= top)
                break;
            [list addObject:@{@"class": [row className],
                              @"live": [NSNumber numberWithInteger:[row live]],
                              @"change": [NSNumber numberWithInteger:[row change]],
                              @"peak": [NSNumber numberWithInteger:[row peak]],
                              @"total": [NSNumber numberWithInteger:[row total]]}];
        }
        return PrintJSON(@{@"program": program,
                           @"seconds": [NSNumber numberWithDouble:seconds],
                           @"liveBefore": [NSNumber numberWithInteger:[first liveTotal]],
                           @"liveAfter": [NSNumber numberWithInteger:[second liveTotal]],
                           @"classes": list});
    }

    Say(@"%ld objects alive, %+ld over %.0f seconds",
        (long)[second liveTotal], (long)grown, seconds);
    Say(@"");
    Say(@"%9s %10s %10s %12s  %@", "CHANGE", "ALIVE", "MOST", "EVER MADE", @"CLASS");
    NSUInteger printed = 0;
    for (PRCensusRow *row in rows) {
        if (printed++ >= top)
            break;
        Say(@"%+9ld %10ld %10ld %12ld  %@", (long)[row change], (long)[row live],
            (long)[row peak], (long)[row total], [row className]);
    }
    return 0;
}

/* profiler record */

@interface PRRecordWaiter : NSObject <PRRecorderDelegate>
{
    PRProfile *_profile;
    NSError *_error;
    BOOL _finished;
    BOOL _quiet;
}
@property (nonatomic, readonly, strong) PRProfile *profile;
@property (nonatomic, readonly, strong) NSError *error;
@property (nonatomic, assign) BOOL quiet;
- (BOOL)waitUntilFinished;
@end

@implementation PRRecordWaiter

@synthesize profile = _profile;
@synthesize error = _error;
@synthesize quiet = _quiet;

- (void)recorder:(PRRecorder *)recorder didReportStatus:(NSString *)status
{
    (void)recorder;
    /* Progress belongs on standard error: standard output is the answer. */
    if (!_quiet)
        fprintf(stderr, "%s\n", [status UTF8String]);
}

- (void)recorder:(PRRecorder *)recorder
    didFinishWithProfile:(PRProfile *)profile
                   error:(NSError *)error
{
    (void)recorder;
    _profile = profile;
    _error = error;
    _finished = YES;
}

/* The recorders report through the run loop, so the tool has to run one. */
- (BOOL)waitUntilFinished
{
    NSRunLoop *loop = [NSRunLoop currentRunLoop];
    while (!_finished) {
        @autoreleasepool {
            if (![loop runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]])
                [NSThread sleepForTimeInterval:0.05];
        }
    }
    return _profile != nil;
}

@end

static int PrintProfileTree(PRProfile *profile, NSUInteger top, BOOL tree,
                            BOOL inverted, NSString *output);

static int Record(NSArray *words, NSArray *arguments, NSUInteger top)
{
    BOOL memory = Flag(arguments, @"--memory");
    NSString *pidText = Option(arguments, @"--pid", nil);
    NSTimeInterval seconds = [Option(arguments, @"--for", @"10") doubleValue];
    NSString *output = Option(arguments, @"-o", nil);

    PRRecordRequest *request = [[PRRecordRequest alloc] init];
    [request setMode:memory ? PRProfileModeMemory : PRProfileModeCPU];
    [request setFrequency:(NSUInteger)[Option(arguments, @"--rate", @"999") integerValue]];
    [request setCallGraph:PRCallGraphDwarf];
    [request setDuration:seconds];

    NSString *cost = Option(arguments, @"--cost", @"peak");
    if ([cost isEqualToString:@"leaked"])
        [request setMemoryCost:PRMemoryCostLeaked];
    else if ([cost isEqualToString:@"allocations"])
        [request setMemoryCost:PRMemoryCostAllocations];
    else if ([cost isEqualToString:@"temporary"])
        [request setMemoryCost:PRMemoryCostTemporary];
    else
        [request setMemoryCost:PRMemoryCostPeak];

    if (pidText != nil) {
        [request setPid:(pid_t)[pidText intValue]];
        [request setTargetName:[NSString stringWithFormat:@"process %@", pidText]];
    } else if ([words count] > 1) {
        [request setLaunchPath:[words objectAtIndex:1]];
        if ([words count] > 2)
            [request setArguments:[words subarrayWithRange:
                                   NSMakeRange(2, [words count] - 2)]];
        [request setTargetName:[[words objectAtIndex:1] lastPathComponent]];
    } else {
        return Fail(@"name what to record: profiler record --pid <pid>, or "
                    @"profiler record <program> [arguments]");
    }

    Class recorderClass = [PRRecorderFactory recorderClassForMode:[request mode]];
    if (recorderClass == nil)
        return Fail(@"No tool on this system can record that.");

    NSString *warning = [recorderClass warningForRequest:request];
    if (warning != nil)
        fprintf(stderr, "%s\n", [warning UTF8String]);

    PRRecorder *recorder = [[recorderClass alloc] init];
    PRRecordWaiter *waiter = [[PRRecordWaiter alloc] init];
    [waiter setQuiet:gJSON];
    [recorder setDelegate:waiter];

    NSError *error = nil;
    if (![recorder startWithRequest:request error:&error])
        return Fail([error localizedDescription]);

    if (![waiter waitUntilFinished]) {
        NSError *failure = [waiter error];
        return Fail(failure ? [failure localizedDescription] :
                    @"The recording produced nothing.");
    }
    return PrintProfileTree([waiter profile], top,
                            Flag(arguments, @"--tree"),
                            Flag(arguments, @"--inverted"), output);
}

/* profiler allocations */

static int Allocations(NSArray *words, NSArray *arguments, NSUInteger top)
{
    if ([words count] < 2)
        return Fail(@"name a process: profiler allocations <pid>");

    pid_t pid = (pid_t)[[words objectAtIndex:1] intValue];
    NSTimeInterval seconds = [Option(arguments, @"--for", @"30") doubleValue];
    NSString *minimum = Option(arguments, @"--min", @"1M");
    unsigned long long bytes = (unsigned long long)[minimum longLongValue];

    if ([minimum hasSuffix:@"M"] || [minimum hasSuffix:@"m"])
        bytes *= 1024ULL * 1024ULL;
    else if ([minimum hasSuffix:@"k"] || [minimum hasSuffix:@"K"])
        bytes *= 1024ULL;
    if (bytes == 0)
        return Fail(@"--min wants a size, such as 1M or 256k.");

    if (!gJSON)
        fprintf(stderr, "Watching process %d for %.0f seconds...\n",
                (int)pid, seconds);

    NSError *error = nil;
    NSArray *sites = [PRAllocationTrace sitesForProcess:pid
                                                minimum:bytes
                                                seconds:seconds
                                                  error:&error];
    if (sites == nil)
        return Fail([error localizedDescription]);

    unsigned long long total = 0;
    for (PRAllocationSite *site in sites)
        total += [site byteCount];

    if (gJSON) {
        NSMutableArray *list = [NSMutableArray array];
        for (PRAllocationSite *site in sites) {
            if ([list count] >= top)
                break;
            [list addObject:@{@"bytes": [NSNumber numberWithUnsignedLongLong:
                                         [site byteCount]],
                              @"count": [NSNumber numberWithUnsignedInteger:
                                         [site count]],
                              @"frames": [site tellingFrames]}];
        }
        return PrintJSON(@{@"pid": [NSNumber numberWithInt:(int)pid],
                           @"seconds": [NSNumber numberWithDouble:seconds],
                           @"minimum": [NSNumber numberWithUnsignedLongLong:bytes],
                           @"bytes": [NSNumber numberWithUnsignedLongLong:total],
                           @"sites": list});
    }

    if ([sites count] == 0) {
        Say(@"No allocation of %@ or more in %.0f seconds.",
            [PRFormat stringForBytes:(double)bytes], seconds);
        return 0;
    }

    NSUInteger times = 0;
    for (PRAllocationSite *site in sites)
        times += [site count];

    Say(@"%@ asked for %lu times from %lu place%@ over %.0f seconds",
        [PRFormat stringForBytes:(double)total], (unsigned long)times,
        (unsigned long)[sites count], [sites count] == 1 ? @"" : @"s", seconds);

    NSUInteger printed = 0;
    for (PRAllocationSite *site in sites) {
        if (printed++ >= top)
            break;
        Say(@"");
        Say(@"%@ in %lu:", [PRFormat stringForBytes:(double)[site byteCount]],
            (unsigned long)[site count]);
        for (NSString *frame in [site tellingFrames])
            Say(@"    %@", frame);
    }
    return 0;
}

/* profiler report */

static void PrintTree(PRCallNode *node, double total, PRCostUnit unit,
                      NSUInteger frequency, NSUInteger depth, NSUInteger limit)
{
    if (depth > limit)
        return;

    PRSymbol *symbol = [node symbol];
    NSString *name = symbol ? [symbol displayName] : [node label];
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++)
        [indent appendString:@"  "];

    Say(@"%10s %7s  %@%@",
        [[PRFormat stringForWeight:[node totalWeight] unit:unit frequency:frequency] UTF8String],
        [[PRFormat percentOf:[node totalWeight] total:total] UTF8String],
        indent, name);

    NSArray *children = [[node children] sortedArrayUsingComparator:
                         ^NSComparisonResult(PRCallNode *a, PRCallNode *b) {
        if ([a totalWeight] > [b totalWeight]) return NSOrderedAscending;
        if ([a totalWeight] < [b totalWeight]) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (PRCallNode *child in children)
        PrintTree(child, total, unit, frequency, depth + 1, limit);
}

static int ReadRecording(NSArray *words, NSUInteger top, BOOL tree, BOOL inverted)
{
    if ([words count] < 2)
        return Fail(@"name the recording to read: profiler report <file.folded>");

    NSString *path = [words objectAtIndex:1];
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text == nil)
        return Fail([NSString stringWithFormat:@"%@ cannot be read.", path]);

    PRProfile *profile = [[PRProfile alloc] init];
    [profile setCostUnit:PRCostUnitSamples];
    PRFoldedStackParser *parser = [[PRFoldedStackParser alloc] initWithProfile:profile];
    [parser parseString:text];

    if ([profile sampleCount] == 0)
        return Fail([NSString stringWithFormat:@"%@ holds no stacks.", path]);

    [profile setTitle:[path lastPathComponent]];

    return PrintProfileTree(profile, top, tree, inverted, nil);
}

static int PrintProfileTree(PRProfile *profile, NSUInteger top, BOOL tree,
                            BOOL inverted, NSString *output)
{
    PRCostUnit unit = [profile costUnit];
    NSUInteger frequency = 999;
    double total = [profile totalWeight];

    if (output != nil) {
        NSError *error = nil;
        if (![profile writeFoldedStacksToPath:output error:&error])
            return Fail([error localizedDescription]);
        fprintf(stderr, "Recording written to %s\n", [output UTF8String]);
    }

    if (tree) {
        PRCallNode *root = [profile callTreeInverted:inverted
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        if (gJSON)
            return Fail(@"--tree and --json cannot be used together yet.");
        Say(@"%10s %7s  %@", "COST", "SHARE", @"CALL PATH");
        PrintTree(root, total, unit, frequency, 0, top);
        return 0;
    }

    NSArray *rows = [profile aggregateByGrouping:PRGroupingFunction
                                           range:PRTimeRangeAll()
                                          thread:PR_ALL_THREADS];
    if (gJSON) {
        NSMutableArray *list = [NSMutableArray array];
        for (PRAggregateRow *row in rows) {
            if ([list count] >= top)
                break;
            [list addObject:@{@"name": [row name] ? [row name] : @"",
                              @"detail": [row detail] ? [row detail] : @"",
                              @"self": [NSNumber numberWithDouble:[row selfWeight]],
                              @"total": [NSNumber numberWithDouble:[row totalWeight]],
                              @"share": [NSNumber numberWithDouble:
                                         total > 0 ? [row selfWeight] / total : 0.0]}];
        }
        return PrintJSON(@{@"file": [profile title] ? [profile title] : @"",
                           @"unit": [PRFormat nameOfUnit:unit],
                           @"total": [NSNumber numberWithDouble:total],
                           @"stacks": [NSNumber numberWithUnsignedInteger:
                                       [profile sampleCount]],
                           @"functions": list});
    }

    Say(@"%@ - %@ on %lu call paths",
        [profile title] ? [profile title] : @"recording",
        [PRFormat stringForWeight:total unit:unit frequency:frequency],
        (unsigned long)[profile sampleCount]);
    Say(@"");
    Say(@"%10s %7s %10s  %@", "SELF", "SHARE", "INCLUSIVE", @"FUNCTION");
    NSUInteger printed = 0;
    for (PRAggregateRow *row in rows) {
        if (printed++ >= top)
            break;
        Say(@"%10s %7s %10s  %@",
            [[PRFormat stringForWeight:[row selfWeight] unit:unit frequency:frequency] UTF8String],
            [[PRFormat percentOf:[row selfWeight] total:total] UTF8String],
            [[PRFormat stringForWeight:[row totalWeight] unit:unit frequency:frequency] UTF8String],
            [row name]);
    }
    return 0;
}

static int Usage(void)
{
    Say(@"Usage: profiler <command> [options]");
    Say(@"");
    Say(@"  memory <pid>            where that process's memory sits");
    Say(@"  memory --all            every process, biggest first");
    Say(@"  objects <program> [..]  start a program and say which classes grow");
    Say(@"  record <program>|--pid N  record it and say where the cost went");
    Say(@"  allocations <pid>       watch for large allocations and name them");
    Say(@"  report <file.folded>    read a recording and say where the cost went");
    Say(@"");
    Say(@"  --json                  print the answer as JSON");
    Say(@"  --by kind|file          how to add up the memory (default kind)");
    Say(@"  --for <seconds>         how long to watch (objects, default 30)");
    Say(@"  --top <rows>            how many rows to print (default 20)");
    Say(@"  --tree [--inverted]     print the call tree instead of the list");
    Say(@"  --memory [--cost ..]    record the heap instead of the processor");
    Say(@"  --rate <n>              samples per second while recording");
    Say(@"  --min <size>            smallest allocation to report, e.g. 1M");
    Say(@"  -o <file.folded>        keep the recording");
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSArray *arguments = [[NSProcessInfo processInfo] arguments];
        NSArray *words = Words(arguments);
        NSString *command = [words count] > 1 ? [words objectAtIndex:1] : nil;

        gJSON = Flag(arguments, @"--json");
        /* In a terminal sudo can ask for the password itself. */
        [PRPrivilegedTask setMayAskOnTerminal:isatty(STDIN_FILENO) ? YES : NO];
        NSUInteger top = (NSUInteger)[Option(arguments, @"--top", @"20") integerValue];
        NSTimeInterval seconds = [Option(arguments, @"--for", @"30") doubleValue];
        NSString *by = Option(arguments, @"--by", @"kind");

        if (command == nil || Flag(arguments, @"--help") || Flag(arguments, @"-h"))
            return Usage();

        if ([command isEqualToString:@"memory"]) {
            if (Flag(arguments, @"--all"))
                return MemoryOfEveryProcess();
            if ([words count] < 3)
                return Fail(@"name a process: profiler memory <pid>, or --all");
            return MemoryOfProcess((pid_t)[[words objectAtIndex:2] intValue], by);
        }
        if ([command isEqualToString:@"objects"])
            return WatchObjects([words subarrayWithRange:NSMakeRange(1, [words count] - 1)],
                                seconds, top);
        if ([command isEqualToString:@"record"])
            return Record([words subarrayWithRange:NSMakeRange(1, [words count] - 1)],
                          arguments, top);
        if ([command isEqualToString:@"allocations"])
            return Allocations([words subarrayWithRange:NSMakeRange(1, [words count] - 1)],
                               arguments, top);
        if ([command isEqualToString:@"report"])
            return ReadRecording([words subarrayWithRange:NSMakeRange(1, [words count] - 1)],
                                 top, Flag(arguments, @"--tree"),
                                 Flag(arguments, @"--inverted"));

        return Fail([NSString stringWithFormat:@"%@ is not a command. Try --help.",
                     command]);
    }
}
