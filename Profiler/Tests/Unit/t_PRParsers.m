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

static NSString * const kPerfScript =
@"Workspace    8821/8821    43226.865133: cycles:P: \n"
@"\t    7f100fe2b90a objc_msgSend (/System/Library/Libraries/libobjc.so.4.6)\n"
@"\t    7f100f4ba493 _i_NSRunLoop__acceptInputForMode_beforeDate_ (/System/Library/Libraries/libgnustep-base.so.1.31.1)\n"
@"\t    7f100fb6d3af [unknown] (/System/Library/Libraries/libgnustep-gui.so.0.32.0 (deleted))\n"
@"\n"
@"Workspace    8821/8830    43226.897909: cycles:P: \n"
@"\t    7f100f41065c GSIMapNodeForKeyInBucket (/System/Library/Libraries/libgnustep-base.so.1.31.1)\n"
@"\t    7f100f4ba493 _i_NSRunLoop__acceptInputForMode_beforeDate_ (/System/Library/Libraries/libgnustep-base.so.1.31.1)\n"
@"\t    7f100fb6d3af [unknown] (/System/Library/Libraries/libgnustep-gui.so.0.32.0 (deleted))\n"
@"\n";

int main(void)
{
    @autoreleasepool {
        START_SET("perf script parser")

        PRProfile *profile = [[PRProfile alloc] init];
        PRPerfScriptParser *parser = [[PRPerfScriptParser alloc]
                                      initWithProfile:profile];
        [parser parseString:kPerfScript];

        PASS([profile sampleCount] == 2, "two samples parsed");
        PASS([profile totalWeight] == 2.0, "each sample weighs one");
        PASS_EQUAL([profile nameForThread:8821], @"Workspace", "command name");
        PASS([[profile threads] count] == 2, "two threads seen");
        PASS(fabs([profile startTime] - 43226.865133) < 0.000001,
             "first timestamp");
        PASS(fabs([profile endTime] - 43226.897909) < 0.000001,
             "last timestamp");

        PRCallNode *root = [profile callTreeInverted:NO
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        PASS([[root children] count] == 1, "one common outermost frame");
        PRCallNode *outer = [[root children] objectAtIndex:0];
        PASS_EQUAL([[outer symbol] moduleName], @"libgnustep-gui.so.0.32.0",
                   "outermost frame is the one perf printed last");
        PASS([outer totalWeight] == 2.0, "both samples run through it");
        PRCallNode *runLoop = [[outer children] objectAtIndex:0];
        PASS_EQUAL([[runLoop symbol] displayName],
                   @"-[NSRunLoop acceptInputForMode:beforeDate:]",
                   "second frame is demangled");
        PASS([[runLoop children] count] == 2, "two different leaves");
        PASS([runLoop selfWeight] == 0.0, "inner frames carry no self cost");

        PRCallNode *inverted = [profile callTreeInverted:YES
                                                   range:PRTimeRangeAll()
                                                  thread:PR_ALL_THREADS];
        PASS([[inverted children] count] == 2,
             "bottom up tree starts at the two leaves");
        PRCallNode *leaf = [[inverted children] objectAtIndex:0];
        PASS([leaf selfWeight] == 0.0,
             "self cost of a bottom up root sits at its deepest node");
        PASS([leaf totalWeight] == 1.0, "one sample below each leaf");

        PRCallNode *oneThread = [profile callTreeInverted:NO
                                                    range:PRTimeRangeAll()
                                                   thread:8830];
        PASS([oneThread totalWeight] == 1.0, "thread filter");

        PRTimeRange window;
        window.start = 43226.0;
        window.end = 43226.87;
        PRCallNode *windowed = [profile callTreeInverted:NO
                                                   range:window
                                                  thread:PR_ALL_THREADS];
        PASS([windowed totalWeight] == 1.0, "time range filter");

        END_SET("perf script parser")

        START_SET("folded stack parser")

        PRProfile *profile = [[PRProfile alloc] init];
        [profile setCostUnit:PRCostUnitBytes];
        PRFoldedStackParser *parser = [[PRFoldedStackParser alloc]
                                       initWithProfile:profile];
        [parser parseString:
         @"main (m.c);leaky (m.c); 5000000\n"
         @"main (m.c);churn (m.c); 4096\n"
         @"\n"];

        PASS([profile sampleCount] == 2, "two allocation sites");
        PASS([profile totalWeight] == 5004096.0, "weights are bytes");

        PRCallNode *root = [profile callTreeInverted:NO
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        PRCallNode *main = [[root children] objectAtIndex:0];
        PASS_EQUAL([[main symbol] displayName], @"main", "frame name");
        PASS_EQUAL([[main symbol] moduleName], @"m.c",
                   "parenthesised suffix is the module");
        PASS([[main children] count] == 2, "two call sites below main");
        PASS([[[main children] objectAtIndex:0] totalWeight] == 5000000.0,
             "children are sorted by cost");

        END_SET("folded stack parser")

        START_SET("DTrace aggregation parser")

        PRProfile *profile = [[PRProfile alloc] init];
        PRDTraceStackParser *parser = [[PRDTraceStackParser alloc]
                                       initWithProfile:profile];
        [parser parseString:
         @"\n"
         @"              libgnustep-base.so.1`_i_NSRunLoop__runMode_beforeDate_+0x2a\n"
         @"              Workspace`main+0x1f\n"
         @"               17\n"
         @"\n"];

        PASS([profile sampleCount] == 1, "one aggregated stack");
        PASS([profile totalWeight] == 17.0, "aggregated count is the weight");
        PRCallNode *root = [profile callTreeInverted:NO
                                               range:PRTimeRangeAll()
                                              thread:PR_ALL_THREADS];
        PRCallNode *main = [[root children] objectAtIndex:0];
        PASS_EQUAL([[main symbol] displayName], @"main", "outermost frame");
        PASS_EQUAL([[main symbol] moduleName], @"Workspace", "module of a frame");
        PRCallNode *inner = [[main children] objectAtIndex:0];
        PASS_EQUAL([[inner symbol] displayName],
                   @"-[NSRunLoop runMode:beforeDate:]",
                   "offset is stripped and the name demangled");

        END_SET("DTrace aggregation parser")
    }
    return 0;
}
