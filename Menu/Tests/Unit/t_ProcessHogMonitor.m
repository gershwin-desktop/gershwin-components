/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Coverage for ProcessHogMonitor: which processes the Force Quit panel adds
 * to its list of applications (CPU measured per core between two samples,
 * share of physical memory), what is never offered, how a hog that is also a
 * windowed application is listed once, and how the reason is worded.
 * Headless: the process table is built by hand.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../ProcessHogMonitor.h"
#import "../../../Processes/ProcessInfo.h"

enum { kTicksPerSecond = 100, kOwnPid = 500, kTotalKB = 1000000 };

static ProcessInfo *proc(int pid, NSString *user, NSString *command,
                         unsigned long long ticks, long rssKB)
{
    ProcessInfo *info = [[ProcessInfo alloc] init];
    [info setPid: pid];
    [info setUser: user];
    [info setCommand: command];
    [info setState: @"R"];
    [info setCpuTicks: ticks];
    [info setUsesCPUTicks: YES];
    [info setStartToken: 1000 + pid];
    [info setResidentMemory: rssKB];
    return info;
}

static ProcessHogMonitor *monitor(void)
{
    return [[ProcessHogMonitor alloc] initWithTotalMemoryKB: kTotalKB
                                             ticksPerSecond: kTicksPerSecond
                                                currentUser: @"alice"
                                                     ownPid: kOwnPid];
}

static NSDictionary *hogForPid(NSArray *hogs, int pid)
{
    for (NSDictionary *hog in hogs) {
        if ([[hog objectForKey: @"pid"] intValue] == pid) {
            return hog;
        }
    }
    return nil;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- CPU is a percentage of ONE core between two samples --- */
    {
        ProcessHogMonitor *m = monitor();
        [m hogsAfterSample: [NSArray arrayWithObjects:
            proc(10, @"alice", @"sh -c while", 0, 1000),
            proc(11, @"alice", @"calm", 0, 1000),
            proc(12, @"alice", @"edge", 0, 1000), nil] atTime: 100.0];
        /* One second later: pid 10 used 98 ticks = 98% of a core. */
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObjects:
            proc(10, @"alice", @"sh -c while", 98, 1000),
            proc(11, @"alice", @"calm", 40, 1000),
            proc(12, @"alice", @"edge", 95, 1000), nil] atTime: 101.0];
        NSDictionary *busy = hogForPid(hogs, 10);
        PASS(busy != nil, "a process pinning one core qualifies");
        PASS_EQUAL([busy objectForKey: @"reason"], @"98% CPU",
                   "the reason names the CPU figure");
        PASS(hogForPid(hogs, 11) == nil, "forty percent of a core is not a hog");
        PASS(hogForPid(hogs, 12) == nil, "exactly 95 percent does not exceed the threshold");
    }
    {
        /* The interval, not the number of ticks, sets the percentage. */
        ProcessHogMonitor *m = monitor();
        [m hogsAfterSample: [NSArray arrayWithObject: proc(10, @"alice", @"x", 0, 1)] atTime: 0.0];
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObject: proc(10, @"alice", @"x", 196, 1)] atTime: 2.0];
        PASS(hogForPid(hogs, 10) != nil, "196 ticks in 2 s is 98 percent of a core");
        m = monitor();
        [m hogsAfterSample: [NSArray arrayWithObject: proc(10, @"alice", @"x", 0, 1)] atTime: 0.0];
        hogs = [m hogsAfterSample: [NSArray arrayWithObject: proc(10, @"alice", @"x", 196, 1)] atTime: 4.0];
        PASS([hogs count] == 0, "196 ticks in 4 s is 49 percent");
    }
    {
        /* A pid handed on to a new process must not inherit the old counter. */
        ProcessHogMonitor *m = monitor();
        [m hogsAfterSample: [NSArray arrayWithObject: proc(10, @"alice", @"x", 5000, 1)] atTime: 0.0];
        ProcessInfo *reused = proc(10, @"alice", @"y", 100, 1);
        [reused setStartToken: 99999];
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObject: reused] atTime: 1.0];
        PASS([hogs count] == 0, "a reused pid has no CPU history");
    }
    {
        /* Without a previous sample there is no CPU figure at all. */
        ProcessHogMonitor *m = monitor();
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObject:
            proc(10, @"alice", @"x", 999999, 1)] atTime: 1.0];
        PASS([hogs count] == 0, "the first sample cannot judge CPU");
    }

    /* --- memory is a share of physical memory --- */
    {
        ProcessHogMonitor *m = monitor();
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObjects:
            proc(20, @"alice", @"/usr/bin/bigjob --flag", 0, 610000),
            proc(21, @"alice", @"half", 0, 500000),
            proc(22, @"alice", @"small", 0, 100000), nil] atTime: 1.0];
        NSDictionary *big = hogForPid(hogs, 20);
        PASS(big != nil, "61 percent of memory qualifies on the first sample");
        PASS_EQUAL([big objectForKey: @"reason"], @"61% memory", "the reason names the memory share");
        PASS_EQUAL([big objectForKey: @"name"], @"bigjob", "the name is the executable, not the command line");
        PASS(hogForPid(hogs, 21) == nil, "exactly 50 percent does not exceed the threshold");
        PASS(hogForPid(hogs, 22) == nil, "10 percent is not a hog");
    }
    {
        ProcessHogMonitor *m = monitor();
        [m hogsAfterSample: [NSArray arrayWithObject: proc(30, @"alice", @"both", 0, 700000)] atTime: 0.0];
        NSArray *hogs = [m hogsAfterSample: [NSArray arrayWithObject: proc(30, @"alice", @"both", 100, 700000)] atTime: 1.0];
        PASS_EQUAL([[hogs lastObject] objectForKey: @"reason"], @"100% CPU, 70% memory",
                   "both figures are named when both exceed");
    }

    /* --- what is never offered --- */
    {
        ProcessHogMonitor *m = monitor();
        NSArray *first = [NSArray arrayWithObjects:
            proc(kOwnPid, @"alice", @"Menu", 0, 900000),
            proc(1, @"alice", @"init", 0, 900000),
            proc(40, @"bob", @"theirs", 0, 900000),
            proc(41, @"alice", @"mine", 0, 900000), nil];
        NSArray *hogs = [m hogsAfterSample: first atTime: 0.0];
        PASS(hogForPid(hogs, kOwnPid) == nil, "the panel's own process is never listed");
        PASS(hogForPid(hogs, 1) == nil, "pid 1 is never listed");
        PASS(hogForPid(hogs, 40) == nil, "another user's process is never listed");
        PASS(hogForPid(hogs, 41) != nil, "the current user's process is listed");
        ProcessInfo *zombie = proc(42, @"alice", @"gone", 0, 900000);
        [zombie setState: @"Z"];
        hogs = [m hogsAfterSample: [NSArray arrayWithObject: zombie] atTime: 1.0];
        PASS([hogs count] == 0, "a zombie cannot be killed and is not listed");
    }
    {
        /* Processes whose ticks were not readable never qualify on CPU. */
        ProcessHogMonitor *m = monitor();
        ProcessInfo *a = proc(50, @"alice", @"x", 0, 1);
        [a setUsesCPUTicks: NO];
        ProcessInfo *b = proc(50, @"alice", @"x", 9999, 1);
        [b setUsesCPUTicks: NO];
        [m hogsAfterSample: [NSArray arrayWithObject: a] atTime: 0.0];
        PASS([[m hogsAfterSample: [NSArray arrayWithObject: b] atTime: 1.0] count] == 0,
             "no tick counter, no CPU figure");
    }

    /* --- rows: applications first, a hog that owns a window appears once --- */
    {
        NSArray *apps = [NSArray arrayWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys: @"Zeta", @"name", [NSNumber numberWithInt: 60], @"pid", nil],
            [NSDictionary dictionaryWithObjectsAndKeys: @"alpha", @"name", [NSNumber numberWithInt: 61], @"pid", nil], nil];
        NSArray *hogs = [NSArray arrayWithObjects:
            [NSDictionary dictionaryWithObjectsAndKeys: @"zzjob", @"name", [NSNumber numberWithInt: 70], @"pid", @"99% CPU", @"reason", nil],
            [NSDictionary dictionaryWithObjectsAndKeys: @"Zeta", @"name", [NSNumber numberWithInt: 60], @"pid", @"98% CPU", @"reason", nil],
            [NSDictionary dictionaryWithObjectsAndKeys: @"aajob", @"name", [NSNumber numberWithInt: 71], @"pid", @"61% memory", @"reason", nil], nil];
        NSArray *rows = [ProcessHogMonitor rowsForApplications: apps hogs: hogs];
        PASS([rows count] == 4, "the windowed hog is listed once (4 rows, got %lu)", (unsigned long)[rows count]);
        PASS_EQUAL([[rows objectAtIndex: 0] objectForKey: @"name"], @"alpha", "applications come first, by name");
        PASS_EQUAL([[rows objectAtIndex: 1] objectForKey: @"name"], @"Zeta", "the busy application stays in the application block");
        PASS_EQUAL([[rows objectAtIndex: 1] objectForKey: @"detail"], @"98% CPU", "the busy application carries its figure");
        PASS([[[rows objectAtIndex: 0] objectForKey: @"detail"] length] == 0, "a calm application carries no figure");
        PASS_EQUAL([[rows objectAtIndex: 2] objectForKey: @"name"], @"aajob", "plain processes follow, by name");
        PASS_EQUAL([[rows objectAtIndex: 3] objectForKey: @"detail"], @"99% CPU", "a plain process carries its reason");
        PASS([[[rows objectAtIndex: 1] objectForKey: @"application"] boolValue], "application rows are marked");
        PASS(![[[rows objectAtIndex: 2] objectForKey: @"application"] boolValue], "process rows are not");
    }

    [arp release];
    return 0;
}
