/* t_ProcessHealth.m - ObjectTesting coverage for the process health verdicts.
 * Headless: the history is fed synthetic samples with a synthetic clock.
 *
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ProcessHealth.h"

static NSString * const kToolDescription = @"ProcessHealth verdict tests";

/* Feeds "count" samples, one every "step" seconds, starting at "t0".
 * The resident size starts at rssKB and grows by growthKB per sample. */
static void feed(ProcessHistory *h, int pid, NSTimeInterval t0, double step,
                 int count, long rssKB, long growthKB, float cpu,
                 int threads, unichar state)
{
    int i;
    for (i = 0; i < count; i++) {
        [h beginRound];
        [h notePid: pid
             token: 4242
        residentKB: rssKB + (long)i * growthKB
               cpu: cpu
           threads: threads
       majorFaults: 0
             state: state
            atTime: t0 + (double)i * step];
        [h endRound];
    }
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSTimeInterval t0 = 1000000.0;

    /* --- a quiet process has nothing to report --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        feed(h, 100, t0, 30.0, 60, 40 * 1024, 0, 1.0, 4, 'S');
        ProcessHealth *v = [h healthForPid: 100];
        PASS([v level] == ProcessHealthLevelOK, "a steady process is healthy");
        PASS([v summary] == nil, "a healthy process has no summary");
        PASS([[v issues] count] == 0, "a healthy process has no issues");
    }

    /* --- resident memory that only ever grows is a leak --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        /* 2.5 MB per 30 s sample = 5 MB/min over 30 minutes */
        feed(h, 101, t0, 30.0, 60, 40 * 1024, 2560, 1.0, 4, 'S');
        ProcessHealth *v = [h healthForPid: 101];
        PASS([v level] == ProcessHealthLevelProblem, "a fast leak is a problem");
        PASS([[v summary] hasPrefix: @"Memory"], "the leak summary names memory");
        double rate = [h memoryGrowthMBPerMinuteForPid: 101];
        PASS(rate > 4.5 && rate < 5.5, "the growth rate is ~5 MB/min (got %.2f)", rate);
        PASS([[v explanation] length] > 40, "the leak is explained in prose");
    }

    /* --- a slow but relentless climb is worth watching, not alarming --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        /* 512 KB per 30 s = 1 MB/min over 25 minutes = 25 MB */
        feed(h, 102, t0, 30.0, 51, 40 * 1024, 512, 1.0, 4, 'S');
        ProcessHealth *v = [h healthForPid: 102];
        PASS([v level] == ProcessHealthLevelWatch, "a slow leak is a watch item");
    }

    /* --- memory that falls back is not a leak --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        int i;
        for (i = 0; i < 60; i++) {
            /* sawtooth: climbs 150 MB, drops back every 20 samples */
            long rss = 40 * 1024 + (long)(i % 20) * 7680;
            [h beginRound];
            [h notePid: 103 token: 1 residentKB: rss cpu: 1.0 threads: 4
          majorFaults: 0 state: 'S' atTime: t0 + i * 30.0];
            [h endRound];
        }
        ProcessHealth *v = [h healthForPid: 103];
        PASS([v level] == ProcessHealthLevelOK, "a sawtooth is not called a leak");
    }

    /* --- memory that grew once and then settled is not a leak --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        int i;
        for (i = 0; i < 46; i++) {
            /* 175 MB while warming up, then twenty minutes of flat */
            long rss = 40 * 1024 + (long)((i < 6) ? i : 5) * 35840;
            [h beginRound];
            [h notePid: 105 token: 1 residentKB: rss cpu: 1.0 threads: 4
          majorFaults: 0 state: 'S' atTime: t0 + i * 30.0];
            [h endRound];
        }
        ProcessHealth *v = [h healthForPid: 105];
        PASS([v level] == ProcessHealthLevelOK,
             "a process that grew once and then settled is not leaking");
    }

    /* --- a climb that is still going on is --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        int i;
        for (i = 0; i < 46; i++) {
            /* the same 175 MB, but spread evenly over the whole window */
            long rss = 40 * 1024 + (long)i * 4675;
            [h beginRound];
            [h notePid: 106 token: 1 residentKB: rss cpu: 1.0 threads: 4
          majorFaults: 0 state: 'S' atTime: t0 + i * 30.0];
            [h endRound];
        }
        PASS([[h healthForPid: 106] level] != ProcessHealthLevelOK,
             "a climb that has not stopped is still reported");
    }

    /* --- too short an observation proves nothing --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        feed(h, 104, t0, 30.0, 3, 40 * 1024, 20480, 1.0, 4, 'S');
        ProcessHealth *v = [h healthForPid: 104];
        PASS([v level] == ProcessHealthLevelOK,
             "a minute of growth is not enough for a verdict");
    }

    /* --- sustained high CPU --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        feed(h, 105, t0, 5.0, 7, 40 * 1024, 0, 98.0, 4, 'R');
        PASS([[h healthForPid: 105] level] == ProcessHealthLevelOK,
             "half a minute of busy CPU is normal work");

        feed(h, 106, t0, 5.0, 25, 40 * 1024, 0, 98.0, 4, 'R');
        ProcessHealth *v = [h healthForPid: 106];
        PASS([v level] == ProcessHealthLevelWatch,
             "two minutes of busy CPU is a watch item");
        PASS([[v summary] hasPrefix: @"CPU"], "the CPU summary names the CPU");

        feed(h, 107, t0, 5.0, 80, 40 * 1024, 0, 98.0, 4, 'R');
        PASS([[h healthForPid: 107] level] == ProcessHealthLevelProblem,
             "a process pegged for minutes is a problem");
        NSTimeInterval busy = [h highCPUDurationForPid: 107];
        PASS(busy > 390.0 && busy < 400.0, "the busy run is measured (got %.0f s)", busy);
    }

    /* --- going idle clears the high CPU run --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        feed(h, 108, t0, 5.0, 80, 40 * 1024, 0, 98.0, 4, 'R');
        [h beginRound];
        [h notePid: 108 token: 4242 residentKB: 40 * 1024 cpu: 0.5 threads: 4
      majorFaults: 0 state: 'S' atTime: t0 + 400.0];
        [h endRound];
        PASS([[h healthForPid: 108] level] == ProcessHealthLevelOK,
             "one idle sample ends the busy run");
        PASS([h highCPUDurationForPid: 108] == 0.0, "the busy run is reset");
    }

    /* --- states that speak for themselves --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        feed(h, 110, t0, 5.0, 2, 0, 0, 0.0, 1, 'Z');
        ProcessHealth *zombie = [h healthForPid: 110];
        PASS([zombie level] == ProcessHealthLevelProblem, "a zombie is a problem");
        PASS_EQUAL([zombie summary], @"Zombie", "the zombie summary");

        feed(h, 111, t0, 5.0, 1, 40 * 1024, 0, 0.0, 4, 'D');
        PASS([[h healthForPid: 111] level] == ProcessHealthLevelOK,
             "a single uninterruptible sample is ordinary I/O");

        feed(h, 112, t0, 5.0, 10, 40 * 1024, 0, 0.0, 4, 'D');
        ProcessHealth *stuck = [h healthForPid: 112];
        PASS([stuck level] == ProcessHealthLevelProblem,
             "a process stuck in uninterruptible wait is a problem");
        PASS([[stuck summary] hasPrefix: @"Blocked"], "the blocked summary");

        feed(h, 113, t0, 5.0, 4, 40 * 1024, 0, 0.0, 4, 'T');
        ProcessHealth *stopped = [h healthForPid: 113];
        PASS([stopped level] == ProcessHealthLevelWatch, "a stopped process is a watch item");
        PASS([[stopped summary] hasPrefix: @"Suspended"], "the suspended summary");
    }

    /* --- threads that are started and never joined --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        int i;
        for (i = 0; i < 40; i++) {
            [h beginRound];
            [h notePid: 114 token: 7 residentKB: 40 * 1024 cpu: 1.0
              threads: 20 + i * 2 majorFaults: 0 state: 'S'
               atTime: t0 + i * 30.0];
            [h endRound];
        }
        ProcessHealth *v = [h healthForPid: 114];
        PASS([v level] == ProcessHealthLevelWatch, "a growing thread count is a watch item");
        PASS([[v summary] hasPrefix: @"Threads"], "the thread summary");
    }

    /* --- paging storm --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        int i;
        for (i = 0; i < 8; i++) {
            [h beginRound];
            [h notePid: 115 token: 7 residentKB: 400 * 1024 cpu: 30.0 threads: 4
          majorFaults: (unsigned long long)i * 2000 state: 'R'
               atTime: t0 + i * 5.0];
            [h endRound];
        }
        ProcessHealth *v = [h healthForPid: 115];
        PASS([v level] == ProcessHealthLevelWatch, "a paging storm is a watch item");
        PASS([[v summary] hasPrefix: @"Swapping"], "the swapping summary");
    }

    /* --- a process that owns most of the machine --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 8 * 1024 * 1024];
        feed(h, 116, t0, 30.0, 4, 3 * 1024 * 1024, 0, 1.0, 4, 'S');
        ProcessHealth *v = [h healthForPid: 116];
        PASS([v level] == ProcessHealthLevelWatch, "a huge footprint is a watch item");
        PASS([[v summary] hasPrefix: @"Large"], "the footprint summary");
    }

    /* --- several issues at once: worst first, rest counted --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        int i;
        for (i = 0; i < 60; i++) {
            [h beginRound];
            [h notePid: 117 token: 9 residentKB: 40 * 1024 + (long)i * 2560
                  cpu: 99.0 threads: 4 majorFaults: 0 state: 'R'
               atTime: t0 + i * 30.0];
            [h endRound];
        }
        ProcessHealth *v = [h healthForPid: 117];
        PASS([[v issues] count] == 2, "both the leak and the busy CPU are reported");
        PASS([[v summary] hasSuffix: @"(+1)"], "the summary counts the other issue");
        PASS([[v explanation] rangeOfString: @"\n"].location != NSNotFound,
             "the explanation covers both issues");
    }

    /* --- CPU percentage from tick counters --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        float first = [h cpuPercentForPid: 120 token: 1 totalTicks: 1000
                           ticksPerSecond: 100 atTime: t0];
        PASS(first == 0.0, "the first tick reading yields no percentage");
        float busy = [h cpuPercentForPid: 120 token: 1 totalTicks: 1500
                           ticksPerSecond: 100 atTime: t0 + 5.0];
        PASS(busy > 99.0 && busy < 101.0, "500 ticks in 5 s at 100 Hz is 100%% (got %.1f)", busy);
        float idle = [h cpuPercentForPid: 120 token: 1 totalTicks: 1500
                           ticksPerSecond: 100 atTime: t0 + 10.0];
        PASS(idle == 0.0, "no ticks means no CPU");
    }

    /* --- a reused pid does not inherit the old process's history --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        feed(h, 121, t0, 30.0, 60, 40 * 1024, 2560, 1.0, 4, 'S');
        PASS([[h healthForPid: 121] level] == ProcessHealthLevelProblem,
             "the leak is seen before the pid is reused");
        [h beginRound];
        [h notePid: 121 token: 999 residentKB: 40 * 1024 cpu: 1.0 threads: 4
      majorFaults: 0 state: 'S' atTime: t0 + 1800.0];
        [h endRound];
        PASS([[h healthForPid: 121] level] == ProcessHealthLevelOK,
             "a new process with the same pid starts clean");
        PASS([[h residentMBSamplesForPid: 121] count] == 1,
             "the samples of the old process are gone");
    }

    /* --- processes that are gone are forgotten --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h beginRound];
        [h notePid: 130 token: 1 residentKB: 1024 cpu: 0.0 threads: 1
      majorFaults: 0 state: 'S' atTime: t0];
        [h notePid: 131 token: 1 residentKB: 1024 cpu: 0.0 threads: 1
      majorFaults: 0 state: 'S' atTime: t0];
        [h endRound];
        PASS([h trackedProcessCount] == 2, "both processes are tracked");
        [h beginRound];
        [h notePid: 130 token: 1 residentKB: 1024 cpu: 0.0 threads: 1
      majorFaults: 0 state: 'S' atTime: t0 + 5.0];
        [h endRound];
        PASS([h trackedProcessCount] == 1, "the process that vanished is forgotten");
        PASS([h healthForPid: 131] == nil, "an unknown pid has no verdict");
    }

    /* --- the inspector data --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        [h setTotalMemoryKB: 16 * 1024 * 1024];
        feed(h, 140, t0, 30.0, 10, 100 * 1024, 10240, 50.0, 4, 'S');
        NSArray *mem = [h residentMBSamplesForPid: 140];
        PASS([mem count] == 10, "one memory sample per half minute (got %lu)",
             (unsigned long)[mem count]);
        PASS([[mem objectAtIndex: 0] doubleValue] < [[mem lastObject] doubleValue],
             "the memory samples are oldest first");
        PASS([[h cpuSamplesForPid: 140] count] == 10, "one CPU sample per half minute");
        PASS([h peakResidentKBForPid: 140] == 100 * 1024 + 9 * 10240, "the peak is kept");
        NSTimeInterval seen = [h observedDurationForPid: 140];
        PASS(seen > 269.0 && seen < 271.0, "the observed span is 270 s (got %.0f)", seen);
    }

    /* --- samples do not grow without bound --- */
    {
        ProcessHistory *h = [ProcessHistory new];
        feed(h, 141, t0, 30.0, 400, 40 * 1024, 0, 1.0, 4, 'S');
        NSUInteger kept = [[h residentMBSamplesForPid: 141] count];
        PASS(kept > 10 && kept <= 120, "the sample window is capped (kept %lu)",
             (unsigned long)kept);
    }

    NSLog(@"%@ done", kToolDescription);
    [arp release];
    return 0;
}
