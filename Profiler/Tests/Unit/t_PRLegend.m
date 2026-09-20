/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "ObjectTesting.h"
#import "PRProfile.h"
#import "PRCallNode.h"
#import "PRSymbol.h"
#import "PRFlameGraphView.h"
#import "PRLegendView.h"

static void addStack(PRProfile *profile, NSArray *pairs, double weight)
{
    NSMutableArray *symbols = [NSMutableArray array];
    NSUInteger i;
    for (i = 0; i + 1 < [pairs count]; i += 2)
        [symbols addObject:[profile symbolWithName:[pairs objectAtIndex:i]
                                        modulePath:[pairs objectAtIndex:i + 1]]];
    [profile addSampleWithSymbols:symbols weight:weight time:1.0 thread:1];
}

static NSArray *labels(NSArray *entries)
{
    NSMutableArray *result = [NSMutableArray array];
    for (PRLegendEntry *entry in entries)
        [result addObject:[entry label]];
    return result;
}

int main(void)
{
    @autoreleasepool {
        START_SET("Flame graph legend")

        PRProfile *profile = [[PRProfile alloc] init];
        /* Two binaries, the kernel and a frame no symbol could be found for. */
        addStack(profile, @[@"main", @"/usr/bin/app",
                            @"draw", @"/usr/lib/libgui.so"], 10.0);
        addStack(profile, @[@"main", @"/usr/bin/app",
                            @"write", @"[kernel.kallsyms]"], 4.0);
        addStack(profile, @[@"main", @"/usr/bin/app",
                            @"[unknown]", @"/usr/lib/libgui.so"], 2.0);

        PRCallNode *root = [profile callTreeInverted:NO
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        PRFlameGraphView *graph = [[PRFlameGraphView alloc] initWithFrame:
                                   NSMakeRect(0, 0, 600, 400)];
        [graph setRoot:root];

        NSArray *names = labels([graph legendEntries]);
        PASS([names count] == 4, "one key per binary plus kernel and unknown");
        PASS_EQUAL([names objectAtIndex:0], @"libgui.so",
                   "the heaviest binary comes first");
        PASS_EQUAL([names objectAtIndex:1], @"app", "then the program itself");
        PASS_EQUAL([names objectAtIndex:2], @"Kernel and drivers",
                   "the kernel is named, not coloured by binary");
        PASS_EQUAL([names objectAtIndex:3], @"Code that could not be named",
                   "frames without a symbol are named too");

        /* A search dims everything that does not match, which the legend
           has to say as well. */
        [graph setSearchString:@"draw"];
        PASS([[labels([graph legendEntries]) lastObject]
              isEqualToString:@"Does not match the search"],
             "the dimmed colour is explained while searching");

        /* Folded stacks name no binary at all, so the hues stand for the
           functions themselves and the legend says so. */
        PRProfile *folded = [[PRProfile alloc] init];
        addStack(folded, @[@"main", @"", @"solve", @""], 3.0);
        PRFlameGraphView *foldedGraph = [[PRFlameGraphView alloc] initWithFrame:
                                         NSMakeRect(0, 0, 600, 400)];
        [foldedGraph setRoot:[folded callTreeInverted:NO
                                                range:PRTimeRangeAll()
                                               thread:PR_ALL_THREADS]];
        NSArray *foldedEntries = [foldedGraph legendEntries];
        PASS([foldedEntries count] == 1, "nothing to name but the note");
        PASS([[foldedEntries objectAtIndex:0] color] == nil,
             "the note carries no colour");

        END_SET("Flame graph legend")
    }
    return 0;
}
