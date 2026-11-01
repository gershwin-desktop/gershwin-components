/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "PRProfile.h"
#import "PRStackParser.h"
#import "PRCallNode.h"
#import "PRSymbol.h"

static void addStack(PRProfile *profile, NSArray *names, double time, int32_t thread)
{
    NSMutableArray *symbols = [NSMutableArray array];
    for (NSString *name in names)
        [symbols addObject:[profile symbolWithName:name
                                        modulePath:@"/usr/lib/libtest.so"]];
    [profile addSampleWithSymbols:symbols weight:1.0 time:time thread:thread];
}

int main(void)
{
    @autoreleasepool {
        START_SET("Profile aggregation")

        PRProfile *profile = [[PRProfile alloc] init];
        [profile setName:@"main" forThread:1];
        [profile setName:@"worker" forThread:2];
        addStack(profile, @[@"main", @"_i_Foo__work", @"malloc"], 1.0, 1);
        addStack(profile, @[@"main", @"_i_Foo__work", @"malloc"], 2.0, 1);
        addStack(profile, @[@"main", @"_i_Bar__draw", @"malloc"], 3.0, 2);

        PASS([profile sampleCount] == 3, "three samples");
        PASS([profile symbolCount] == 4, "symbols are interned");

        NSArray *functions = [profile aggregateByGrouping:PRGroupingFunction
                                                    range:PRTimeRangeAll()
                                                   thread:PR_ALL_THREADS];
        PRAggregateRow *top = [functions objectAtIndex:0];
        PASS_EQUAL([top name], @"malloc", "hottest function by self cost");
        PASS([top selfWeight] == 3.0, "self cost of the leaf");
        PASS([top totalWeight] == 3.0, "inclusive cost of the leaf");

        NSArray *classes = [profile aggregateByGrouping:PRGroupingClass
                                                  range:PRTimeRangeAll()
                                                 thread:PR_ALL_THREADS];
        BOOL foundFoo = NO;
        for (PRAggregateRow *row in classes) {
            if ([[row name] isEqualToString:@"Foo"]) {
                foundFoo = YES;
                PASS([row totalWeight] == 2.0, "inclusive cost of class Foo");
                PASS([row selfWeight] == 0.0, "class Foo never sits on a leaf");
            }
        }
        PASS(foundFoo, "cost is grouped by Objective-C class");

        NSArray *threads = [profile aggregateByGrouping:PRGroupingThread
                                                  range:PRTimeRangeAll()
                                                 thread:PR_ALL_THREADS];
        PASS([threads count] == 2, "one row per thread");
        PASS([[threads objectAtIndex:0] selfWeight] == 2.0,
             "threads are sorted by cost");

        NSArray *modules = [profile aggregateByGrouping:PRGroupingModule
                                                  range:PRTimeRangeAll()
                                                 thread:PR_ALL_THREADS];
        PASS([modules count] == 1, "all frames come from one binary");
        PASS([[modules objectAtIndex:0] totalWeight] == 3.0,
             "inclusive cost is counted once per sample, not once per frame");

        PRTimeRange window;
        window.start = 1.5;
        window.end = 3.5;
        PASS([profile weightInRange:window thread:PR_ALL_THREADS] == 2.0,
             "cost inside a time window");
        PASS([profile weightInRange:PRTimeRangeAll() thread:1] == 2.0,
             "cost of one thread");

        NSArray *timeline = [profile timelineWithBucketCount:3];
        PASS([timeline count] == 3, "timeline buckets");
        double sum = 0;
        for (NSNumber *value in timeline)
            sum += [value doubleValue];
        PASS(sum == 3.0, "every sample lands in a bucket");

        END_SET("Profile aggregation")

        START_SET("Recursion")

        PRProfile *profile = [[PRProfile alloc] init];
        addStack(profile, @[@"main", @"recurse", @"recurse", @"recurse"], 1.0, 1);

        NSArray *functions = [profile aggregateByGrouping:PRGroupingFunction
                                                    range:PRTimeRangeAll()
                                                   thread:PR_ALL_THREADS];
        for (PRAggregateRow *row in functions) {
            if ([[row name] isEqualToString:@"recurse"]) {
                PASS([row totalWeight] == 1.0,
                     "a recursive function counts its sample once");
                PASS([row selfWeight] == 1.0, "the innermost frame is its own");
            }
        }

        PRCallNode *root = [profile callTreeInverted:NO
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        PASS([root depth] == 4, "depth of the call tree");

        END_SET("Recursion")

        START_SET("Folded stack export")

        PRProfile *profile = [[PRProfile alloc] init];
        addStack(profile, @[@"main", @"_i_Foo__work"], 1.0, 1);
        addStack(profile, @[@"main", @"_i_Foo__work"], 2.0, 1);
        addStack(profile, @[@"main", @"idle"], 3.0, 1);

        NSString *path = [NSTemporaryDirectory()
                          stringByAppendingPathComponent:@"t_PRProfile.folded"];
        NSError *error = nil;
        PASS([profile writeFoldedStacksToPath:path error:&error],
             "the profile is written as folded stacks");

        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        PASS([[text componentsSeparatedByString:@"\n"] count] == 3,
             "equal stacks are written as one line");
        PASS([text rangeOfString:@"main;-[Foo work] 2"].location != NSNotFound,
             "names are written in source notation with their summed cost");

        PRProfile *reread = [[PRProfile alloc] init];
        PRFoldedStackParser *parser = [[PRFoldedStackParser alloc]
                                       initWithProfile:reread];
        [parser parseString:text];
        PASS([reread totalWeight] == [profile totalWeight],
             "reading the file back gives the same total cost");

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        END_SET("Folded stack export")
    }
    return 0;
}
