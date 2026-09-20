/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "PRCensus.h"

static PRCensusRow *rowNamed(NSArray *rows, NSString *name)
{
    for (PRCensusRow *row in rows)
        if ([[row className] isEqualToString:name])
            return row;
    return nil;
}

int main(void)
{
    @autoreleasepool {
        START_SET("Object census")

        PRCensusSnapshot *before = [PRCensusSnapshot snapshotFromText:
                                    @"100 120 400 NSImage\n"
                                    @"5 9 9 NSWindow\n"
                                    @"3 3 3 My Odd Class\n"
                                    @".\n"];
        PASS([[before rows] count] == 3, "every line becomes a row");
        PASS([before liveTotal] == 108, "the program's live objects are added up");
        PASS_EQUAL([[before rowForClassName:@"NSImage"] className], @"NSImage",
                   "a class is found by name");
        PASS([[before rowForClassName:@"NSImage"] peak] == 120,
             "the peak is read");
        PASS([[before rowForClassName:@"NSImage"] total] == 400,
             "the number ever created is read");
        PASS([[before rowForClassName:@"My Odd Class"] live] == 3,
             "a class name may hold spaces");

        /* Lines the program never sends must not become rows. */
        PRCensusSnapshot *noise = [PRCensusSnapshot snapshotFromText:
                                   @"error this program has no Objective-C runtime\n"];
        PASS([[noise rows] count] == 0, "a refusal holds no rows");

        PRCensusSnapshot *after = [PRCensusSnapshot snapshotFromText:
                                   @"1300 1300 1600 NSImage\n"
                                   @"5 9 9 NSWindow\n"
                                   @"7 7 7 GSMutableArray\n"
                                   @".\n"];
        NSArray *compared = [after rowsComparedWith:before];

        PASS([[compared objectAtIndex:0] change] == 1200,
             "the class that grew most comes first");
        PASS_EQUAL([[compared objectAtIndex:0] className], @"NSImage",
                   "and it is named");
        PASS([rowNamed(compared, @"NSWindow") change] == 0,
             "a class that did not move shows no change");
        PASS([rowNamed(compared, @"GSMutableArray") change] == 7,
             "a class that appeared counts as grown by all of its objects");
        PASS([rowNamed(compared, @"My Odd Class") change] == -3,
             "a class whose objects all went is reported as a loss");
        PASS([rowNamed(compared, @"My Odd Class") live] == 0,
             "and it holds nothing any more");

        END_SET("Object census")
    }
    return 0;
}
