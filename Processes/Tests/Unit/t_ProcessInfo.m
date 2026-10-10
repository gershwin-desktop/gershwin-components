/* t_ProcessInfo.m - ObjectTesting coverage for what a process row says.
 * Headless: the process records are built by hand.
 *
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ProcessInfo.h"

#include <unistd.h>

static NSString * const kToolDescription = @"ProcessInfo row text tests";

static ProcessInfo *processWithState(NSString *state, float cpu)
{
    ProcessInfo *info = [[ProcessInfo alloc] init];
    [info setPid: 4711];
    [info setState: state];
    [info setCpu: cpu];
    [info setCommand: @"/usr/local/bin/somedaemon --serve"];
    return info;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- the status says what the process did, not where it was caught --- */
    {
        /* The kernel reports the state at the instant of sampling, so a
         * process that burns a third of a core is nearly always found
         * "sleeping".  That is what made the column useless. */
        ProcessInfo *working = processWithState(@"S", 32.0);
        PASS_EQUAL([working statusText], @"Working",
                   "a sleeping process that used CPU is working");

        ProcessInfo *busy = processWithState(@"S", 88.0);
        PASS_EQUAL([busy statusText], @"Busy", "most of a core is busy");

        ProcessInfo *idle = processWithState(@"S", 0.0);
        PASS_EQUAL([idle statusText], @"Idle", "a process that did nothing is idle");

        /* The column prints one decimal, so a process the user sees as
         * "1.0" must not be called idle next to it. */
        ProcessInfo *rounded = processWithState(@"S", 0.96);
        PASS_EQUAL([rounded statusText], @"Working",
                   "what the CPU column rounds up to 1.0 counts as working");
        [rounded release];

        ProcessInfo *quiet = processWithState(@"S", 0.4);
        PASS_EQUAL([quiet statusText], @"Idle",
                   "a trace of CPU is still idle");

        ProcessInfo *onCPU = processWithState(@"R", 0.0);
        PASS_EQUAL([onCPU statusText], @"Working",
                   "a running process is working even before the first CPU reading");

        [working release];
        [busy release];
        [idle release];
        [quiet release];
        [onCPU release];
    }

    /* --- states the user has to know about are named --- */
    {
        ProcessInfo *zombie = processWithState(@"Z", 0.0);
        PASS_EQUAL([zombie statusText], @"Zombie", "a zombie is named");

        ProcessInfo *blocked = processWithState(@"D", 0.0);
        PASS_EQUAL([blocked statusText], @"Waiting for I/O",
                   "an uninterruptible wait is named");

        ProcessInfo *stopped = processWithState(@"T", 0.0);
        PASS_EQUAL([stopped statusText], @"Stopped", "a stopped process is named");

        [zombie release];
        [blocked release];
        [stopped release];
    }

    /* --- a finding always wins over the plain activity --- */
    {
        ProcessInfo *leaking = processWithState(@"S", 5.0);
        ProcessIssue *issue =
            [ProcessIssue issueWithLevel: ProcessHealthLevelProblem
                                    rank: 30
                                   label: @"Memory +18 MB/min"
                             explanation: @"It grew and never fell back."];
        [leaking setHealth:
            [ProcessHealth healthWithIssues: [NSArray arrayWithObject: issue]]];
        PASS_EQUAL([leaking statusText], @"Memory +18 MB/min",
                   "the finding is what the row reports");
        PASS([leaking healthLevel] == ProcessHealthLevelProblem,
             "the row sorts by the severity of the finding");
        [leaking release];
    }

    /* --- cumulative CPU time, however "ps" spells it --- */
    {
        /* Where neither /proc nor a known sysctl exists, "ps" is all there
         * is, and its %CPU is an average over the whole life of the process.
         * Its TIME column is a real counter, so the current load can be
         * worked out from the difference between two readings - but only if
         * every spelling of it is understood. */
        PASS(ProcessParseCPUTimeSeconds(@"0:00") == 0.0, "no time at all");
        PASS(EQ(ProcessParseCPUTimeSeconds(@"0:12.34"), 12.34),
             "minutes, seconds and hundredths");
        PASS(EQ(ProcessParseCPUTimeSeconds(@"3:07"), 187.0), "minutes and seconds");
        PASS(EQ(ProcessParseCPUTimeSeconds(@"1:02:03"), 3723.0),
             "hours, minutes and seconds");
        PASS(EQ(ProcessParseCPUTimeSeconds(@"2-03:04:05"), 183845.0),
             "days are separated by a hyphen");
        PASS(ProcessParseCPUTimeSeconds(@"?") == 0.0, "an unreadable figure is no time");
        PASS(ProcessParseCPUTimeSeconds(nil) == 0.0, "no figure is no time");
    }

    /* --- a "ps" line yields a tick counter, not just an average --- */
    {
        ProcessInfo *info = [[ProcessInfo alloc] initWithPsLine:
            @"admin      4711  3.4  1.2 812345 123456 ??  S    22:16   1:02:03 /usr/bin/someprog --flag"];
        PASS([info pid] == 4711, "the pid is read");
        PASS_EQUAL([info user], @"admin", "the owner is read");
        PASS([info residentMemory] == 123456, "the resident size is read");
        PASS([info usesCPUTicks] == YES,
             "the CPU figure is a counter that can be differenced");
        long hz = sysconf(_SC_CLK_TCK);
        PASS([info cpuTicks] == (unsigned long long)(3723.0 * (double)hz),
             "the counter is the cumulative CPU time in ticks");
        [info release];
    }

    /* --- the fallback parses this very system's "ps" --- */
    {
        /* Not a mock: the line comes from the "ps" of the system the test
         * runs on, so the same assertions check the format on Linux and on
         * each BSD. */
        ProcessInfo *own = nil;
        FILE *ps = popen("LC_ALL=C ps aux", "r");
        if (ps != NULL) {
            char line[2048];
            (void)fgets(line, sizeof(line), ps);        /* header */
            while (fgets(line, sizeof(line), ps) != NULL) {
                size_t length = strlen(line);
                if (length > 0 && line[length - 1] == '\n') {
                    line[length - 1] = '\0';
                }
                ProcessInfo *parsed = [[ProcessInfo alloc]
                    initWithPsLine: [NSString stringWithUTF8String: line]];
                if ([parsed pid] == (int)getpid()) {
                    own = parsed;
                    break;
                }
                [parsed release];
            }
            pclose(ps);
        }
        if (own == nil) {
            PASS(0, "this system's ps aux lists the running test");
        } else {
            PASS([[own user] length] > 0, "the owner is parsed from this system's ps");
            PASS([own residentMemory] > 0, "the resident size is parsed (got %ld KB)",
                 [own residentMemory]);
            PASS([[own command] length] > 0, "the command is parsed");
            PASS([own usesCPUTicks] == YES, "the CPU counter is usable");
            /* A test tool that has just started cannot have burned minutes
             * of CPU, and the counter must not be nonsense. */
            double seconds = (double)[own cpuTicks] / (double)sysconf(_SC_CLK_TCK);
            PASS(seconds >= 0.0 && seconds < 60.0,
                 "the CPU time is plausible for a fresh process (got %.2f s)", seconds);
            [own release];
        }
    }

    /* --- the peak is the one the kernel remembers, not ours --- */
    {
        /* Asking this very process: its high-water mark cannot be below what
         * it holds right now, and it must be a real figure. */
        ProcessInfo *own = processWithState(@"R", 1.0);
        [own setPid: (int)getpid()];
        long peak = [own peakResidentMemory];
        PASS(peak > 0, "the kernel's high-water mark is read (got %ld KB)", peak);

        /* Whatever the process list already reported is kept: the BSDs hand
         * the figure over with the list and there is nothing to look up. */
        ProcessInfo *fromList = processWithState(@"S", 0.0);
        [fromList setPid: 1];
        [fromList setPeakResidentMemory: 123456];
        PASS([fromList peakResidentMemory] == 123456,
             "a peak that came with the process list is not overwritten");

        /* A process that is gone has no figure to report, and saying so is
         * better than inventing one. */
        ProcessInfo *gone = processWithState(@"S", 0.0);
        [gone setPid: 0x7FFFFFF];
        PASS([gone peakResidentMemory] == 0, "an unreadable process reports no peak");

        [own release];
        [fromList release];
        [gone release];
    }

    /* --- the process is named the way the user recognizes it --- */
    {
        ProcessInfo *info = processWithState(@"S", 0.0);
        PASS_EQUAL([info displayName], @"somedaemon",
                   "the executable without its path or arguments");
        PASS_EQUAL([info stateDescription], @"Sleeping",
                   "the raw kernel state stays available for the inspector");
        [info release];
    }

    NSLog(@"%@ done", kToolDescription);
    [arp release];
    return 0;
}
