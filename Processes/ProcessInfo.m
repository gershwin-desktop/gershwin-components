/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessInfo.h"

#include <stdio.h>
#include <unistd.h>

double ProcessParseCPUTimeSeconds(NSString *text)
{
    if ([text length] == 0) {
        return 0.0;
    }
    /* Days are separated by a hyphen, everything else by colons, and the
     * last field may carry a fraction: "2-03:04:05", "1:02:03", "0:12.34". */
    double days = 0.0;
    NSString *rest = text;
    NSRange hyphen = [text rangeOfString: @"-"];
    if (hyphen.location != NSNotFound) {
        days = [[text substringToIndex: hyphen.location] doubleValue];
        rest = [text substringFromIndex: NSMaxRange(hyphen)];
    }

    NSArray *fields = [rest componentsSeparatedByString: @":"];
    if ([fields count] == 0 || [fields count] > 3) {
        return 0.0;
    }
    double seconds = 0.0;
    for (NSString *field in fields) {
        if ([field length] == 0) {
            return 0.0;
        }
        seconds = seconds * 60.0 + [field doubleValue];
    }
    return days * 86400.0 + seconds;
}

/* How much of one processor core counts as busy, and as working at all.
 * One clock tick in a five second interval is already 0.2%, so the lower
 * bound has to be well above zero for "idle" to mean idle. */
static const float kStatusBusyPercent = 50.0;
static const float kStatusWorkingPercent = 1.0;

@implementation ProcessInfo

@synthesize pid = _pid;
@synthesize ppid = _ppid;
@synthesize user = _user;
@synthesize cpu = _cpu;
@synthesize memory = _memory;
@synthesize command = _command;
@synthesize state = _state;
@synthesize virtualMemory = _virtualMemory;
@synthesize residentMemory = _residentMemory;
@synthesize tty = _tty;
@synthesize startTime = _startTime;
@synthesize cpuTime = _cpuTime;
@synthesize threads = _threads;
@synthesize peakResidentMemory = _peakResidentMemory;
@synthesize majorFaults = _majorFaults;
@synthesize cpuTicks = _cpuTicks;
@synthesize usesCPUTicks = _usesCPUTicks;
@synthesize startToken = _startToken;
@synthesize health = _health;

- (id)initWithPsLine:(NSString *)line
{
    self = [super init];
    if (self) {
        // Parse ps aux output: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
        NSArray *components = [line componentsSeparatedByString:@" "];
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *comp in components) {
            if ([comp length] > 0) {
                [filtered addObject:comp];
            }
        }
        if ([filtered count] >= 11) {
            _user = [filtered objectAtIndex:0];
            _pid = [[filtered objectAtIndex:1] intValue];
            _cpu = [[filtered objectAtIndex:2] floatValue];
            _memory = [[filtered objectAtIndex:3] floatValue];
            _virtualMemory = [[filtered objectAtIndex:4] longLongValue];
            _residentMemory = [[filtered objectAtIndex:5] longLongValue];
            _tty = [filtered objectAtIndex:6];
            _state = [filtered objectAtIndex:7];
            _startTime = [filtered objectAtIndex:8];
            _cpuTime = [filtered objectAtIndex:9];
            /* The %CPU that "ps" prints is an average over the whole life of
             * the process, which says nothing about what it is doing now.
             * Its cumulative CPU time is a counter, so the difference
             * between two readings gives a real current figure. */
            _cpuTicks = (unsigned long long)(ProcessParseCPUTimeSeconds(_cpuTime) *
                                             (double)sysconf(_SC_CLK_TCK));
            _usesCPUTicks = YES;
            // Command starts from index 10
            NSRange range = NSMakeRange(10, [filtered count] - 10);
            _command = [[filtered subarrayWithRange:range] componentsJoinedByString:@" "];
        }
    }
    return self;
}

- (long)peakResidentMemory
{
    /* The BSDs report the high-water mark with the process list, so there is
     * nothing left to look up. */
    if (_peakResidentMemory > 0) {
        return _peakResidentMemory;
    }
#ifdef __linux__
    /* VmHWM is the kernel's own high-water mark, which reaches back to the
     * start of the process - unlike anything this application could have
     * watched itself. */
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/status", _pid);
    FILE *status = fopen(path, "r");
    if (status != NULL) {
        char line[256];
        while (fgets(line, sizeof(line), status) != NULL) {
            if (strncmp(line, "VmHWM:", 6) == 0) {
                long peak = 0;
                if (sscanf(line, "VmHWM: %ld", &peak) == 1 && peak > 0) {
                    _peakResidentMemory = peak;
                }
                break;
            }
        }
        fclose(status);
    }
#endif
    return _peakResidentMemory;
}

- (NSString *)stateDescription
{
    if ([_state length] == 0) {
        return @"";
    }
    return ProcessStateDescription([_state characterAtIndex: 0]);
}

- (NSString *)statusText
{
    NSString *summary = [_health summary];
    if (summary != nil) {
        return summary;
    }

    unichar state = ([_state length] > 0) ? [_state characterAtIndex: 0] : 0;
    /* States the user has to know about stand for themselves. */
    if (state == 'Z' || state == 'D' || state == 'T' || state == 't' ||
        state == 'X') {
        return [self stateDescription];
    }

    /* Everything else reports what the process DID since the last reading.
     * The kernel's own state is the state at the instant of sampling, so a
     * process that just used a third of a core is almost always caught
     * "sleeping" - true, and of no use to anybody. */
    if (_cpu >= kStatusBusyPercent) {
        return @"Busy";
    }
    if (_cpu >= kStatusWorkingPercent || state == 'R') {
        return @"Working";
    }
    return @"Idle";
}

- (NSInteger)healthLevel
{
    return (_health != nil) ? (NSInteger)[_health level] : 0;
}

- (NSString *)displayName
{
    if ([_command length] == 0) {
        return @"";
    }
    /* The command is the whole command line; the executable is what the user
     * recognizes the process by. */
    NSString *first = [[_command componentsSeparatedByString: @" "] objectAtIndex: 0];
    NSString *name = [first lastPathComponent];
    if ([name length] == 0) {
        return first;
    }
    return name;
}



@end