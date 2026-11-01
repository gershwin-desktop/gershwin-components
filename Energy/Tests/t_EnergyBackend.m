/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The battery charge limit in libEnergyBackend: the range the slider offers
 * and, above all, the order the two charge thresholds are written in.  The
 * kernel refuses a start threshold that is not below the end threshold in
 * force, and an end threshold that is not above the start, so raising the
 * limit and lowering it need the two writes in opposite orders - and getting
 * that wrong fails silently from the user's point of view, the slider shows
 * a value the machine never took.  Headless; a plan is built from the
 * thresholds passed in, so nothing here touches this machine's battery. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "EnergyBackend.h"

static NSString *const kEndPath =
    @"/sys/class/power_supply/BAT0/charge_control_end_threshold";
static NSString *const kStartPath =
    @"/sys/class/power_supply/BAT0/charge_control_start_threshold";

/* The slider moves in 5-point steps, which is also the gap the backend
   leaves between the two thresholds, so those are the levels a plan is ever
   asked for. */
static const int kStep = 5;

static NSArray *Plan(int end, int currentEnd, int currentStart)
{
    return [EnergyBackend chargeThresholdWritePlanForEnd:end
                                              currentEnd:currentEnd
                                            currentStart:currentStart];
}

/* Every write as "end=90" or "start=85", so a test can read what a plan
   does without caring which of the two files it went to. */
static NSArray *Writes(NSArray *plan)
{
    NSMutableArray *writes = [NSMutableArray array];
    for (NSArray *write in plan) {
        BOOL isEnd = [[write objectAtIndex:0] isEqualToString:kEndPath];
        [writes addObject:[NSString stringWithFormat:@"%@=%@",
            isEnd ? @"end" : @"start", [write objectAtIndex:1]]];
    }
    return writes;
}

/* The "end/start" a plan leaves behind, as a string so a failure can carry
   it. */
static NSString *ResultingPair(NSArray *plan, int end, int start)
{
    for (NSArray *write in plan) {
        if ([[write objectAtIndex:0] isEqualToString:kEndPath]) {
            end = [[write objectAtIndex:1] intValue];
        } else {
            start = [[write objectAtIndex:1] intValue];
        }
    }
    return [NSString stringWithFormat:@"%d/%d", end, start];
}

/* Whether the kernel would have accepted every write in the plan, given the
   thresholds it would have in force at that point.  A start is only
   accepted while the end in force is above it, an end only while the start
   in force is at or below it; 100/100 is the "no limit" a driver reads as
   the feature being off rather than as a contradiction. */
static BOOL KernelWouldAccept(NSArray *plan, int end, int start, NSString **refused)
{
    for (NSArray *write in plan) {
        int value = [[write objectAtIndex:1] intValue];
        if ([[write objectAtIndex:0] isEqualToString:kEndPath]) {
            if (value < start) {
                *refused = [NSString stringWithFormat:@"end=%d under start=%d", value, start];
                return NO;
            }
            end = value;
        } else {
            if (value > end) {
                *refused = [NSString stringWithFormat:@"start=%d over end=%d", value, end];
                return NO;
            }
            start = value;
        }
    }
    return YES;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    const int low = [EnergyBackend minimumChargeLimitPercent];
    const int high = [EnergyBackend maximumChargeLimitPercent];

    START_SET("the slider's range leaves room for a start threshold")
    {
        PASS(low == 50, "the lowest level offered is 50, clear of the empty-reserve range");
        PASS(high == 100, "the top of the slider is 100, which means no limit at all");

        PASS([EnergyBackend chargeLimitStartThresholdForEnd:80] == 75,
             "charging resumes 5 points below the level it stopped at");
        PASS([EnergyBackend chargeLimitStartThresholdForEnd:50] == 45,
             "so does the lowest level offered");
        PASS([EnergyBackend chargeLimitStartThresholdForEnd:95] == 90, "and so does 95");
        PASS([EnergyBackend chargeLimitStartThresholdForEnd:100] == 100,
             "the top is the kernel's no-limit and has nothing below it to resume at");
    }
    END_SET("the slider's range leaves room for a start threshold")

    START_SET("lowering and raising need the writes in opposite orders")
    {
        /* PASS_EQUAL cannot take an array literal (the preprocessor splits
           its arguments at every comma), so each expectation is named. */
        NSArray *nothing = @[];
        NSArray *startOnly = @[@"start=75"];
        NSArray *raise = @[@"end=90", @"start=85"];
        NSArray *lower = @[@"start=75", @"end=80"];
        NSArray *lowerToBottom = @[@"start=45", @"end=50"];
        NSArray *raiseToTop = @[@"end=100", @"start=100"];
        NSArray *topStartOnly = @[@"start=100"];

        PASS_EQUAL(Writes(Plan(80, 80, 75)), nothing,
                    "the limit already in force is left alone entirely");
        PASS_EQUAL(Writes(Plan(80, 80, 70)), startOnly,
                   "only a start that drifted is put back");
        PASS_EQUAL(Writes(Plan(90, 80, 75)), raise,
                   "raising: the end goes up first, so the start may follow it");
        PASS_EQUAL(Writes(Plan(80, 95, 90)), lower,
                   "lowering: the start comes down first, so the end may follow it");
        PASS_EQUAL(Writes(Plan(50, 80, 75)), lowerToBottom,
                   "lowering to the bottom of the slider");
        PASS_EQUAL(Writes(Plan(100, 80, 75)), raiseToTop,
                   "raising to the top turns the limit off, both thresholds at 100");
        PASS_EQUAL(Writes(Plan(100, 100, 95)), topStartOnly,
                   "the limit is already off and only the start says otherwise");
    }
    END_SET("lowering and raising need the writes in opposite orders")

    START_SET("no plan the slider can produce would be refused by the kernel")
    {
        /* Every level the slider offers from every pair of thresholds the
           kernel could be holding: no write may be one it would refuse, and
           every plan must land on the level asked for with the start still
           below it.  The first case that breaks is printed, since a set this
           size can only report pass or fail. */
        BOOL accepted = YES, endsRight = YES, startsBelowEnds = YES, onlyThresholds = YES;
        int checked = 0;

        for (int want = low; want <= high; want += kStep) {
            for (int curEnd = low; curEnd <= high; curEnd++) {
                /* Only pairs the kernel would have accepted in the first
                   place, 100/100 included. */
                for (int curStart = 0; curStart <= curEnd; curStart++) {
                    NSArray *plan = Plan(want, curEnd, curStart);
                    NSString *refused = nil;
                    checked++;
                    for (NSArray *write in plan) {
                        NSString *path = [write objectAtIndex:0];
                        if (![path isEqualToString:kEndPath] && ![path isEqualToString:kStartPath]) {
                            if (onlyThresholds) {
                                fprintf(stderr, "want %d from %d/%d: writes %s\n",
                                        want, curEnd, curStart, [path UTF8String]);
                            }
                            onlyThresholds = NO;
                        }
                    }
                    if (accepted && !KernelWouldAccept(plan, curEnd, curStart, &refused)) {
                        fprintf(stderr, "want %d from %d/%d: the kernel would refuse %s\n",
                                want, curEnd, curStart, [refused UTF8String]);
                        accepted = NO;
                    }
                    if (endsRight && ![ResultingPair(plan, curEnd, curStart) isEqualToString:
                            [NSString stringWithFormat:@"%d/%d", want,
                                [EnergyBackend chargeLimitStartThresholdForEnd:want]]]) {
                        fprintf(stderr, "want %d from %d/%d: ended at %s\n",
                                want, curEnd, curStart,
                                [ResultingPair(plan, curEnd, curStart) UTF8String]);
                        endsRight = NO;
                    }
                    NSArray *reached = [ResultingPair(plan, curEnd, curStart)
                        componentsSeparatedByString:@"/"];
                    int end = [[reached objectAtIndex:0] intValue];
                    int start = [[reached objectAtIndex:1] intValue];
                    if (startsBelowEnds && !(start < end || (start == 100 && end == 100))) {
                        fprintf(stderr, "want %d from %d/%d: ended at %d/%d\n",
                                want, curEnd, curStart, end, start);
                        startsBelowEnds = NO;
                    }
                }
            }
        }
        printf("checked %d plans\n", checked);
        PASS(accepted, "every write a plan makes is one the kernel would take");
        PASS(endsRight, "every plan reaches the level the slider asked for");
        PASS(startsBelowEnds, "every plan leaves the start threshold below the end");
        PASS(onlyThresholds, "no plan writes to a file other than the two thresholds");
    }
    END_SET("no plan the slider can produce would be refused by the kernel")

    START_SET("applying a limit the machine already has costs nothing")
    {
        NSArray *first = Plan(80, 80, [EnergyBackend chargeLimitStartThresholdForEnd:80]);
        NSArray *again = Plan(80, 80, [EnergyBackend chargeLimitStartThresholdForEnd:80]);
        NSArray *drifted = Plan(80, 80, 70);
        PASS([first count] == 0, "no write at all when the level asked for is the one in force");
        PASS([again count] == [first count],
             "asking a second time changes nothing, so a second login writes nothing");
        PASS([drifted count] == 1,
             "a start that drifted is still noticed, so the pair cannot rot apart");
    }
    END_SET("applying a limit the machine already has costs nothing")

    [arp release];
    return 0;
}
