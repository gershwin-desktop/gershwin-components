/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

#import "ProcessHealth.h"

@interface ProcessInfo : NSObject
{
    int _pid;
    int _ppid;
    NSString *_user;
    float _cpu;
    float _memory;
    NSString *_command;
    NSString *_state;
    long _virtualMemory;
    long _residentMemory;
    NSString *_tty;
    NSString *_startTime;
    NSString *_cpuTime;

    int _threads;
    /* The most resident memory the process ever held, as the kernel
     * remembers it over the whole life of the process. */
    long _peakResidentMemory;
    unsigned long long _majorFaults;
    /* Cumulative user+system CPU ticks, and whether they were readable: the
     * CPU percentage is the difference between two readings. */
    unsigned long long _cpuTicks;
    BOOL _usesCPUTicks;
    /* Tells one process from the next one to be handed the same pid. */
    unsigned long long _startToken;

    ProcessHealth *_health;
}

@property (nonatomic, assign) int pid;
@property (nonatomic, assign) int ppid;
@property (nonatomic, strong) NSString *user;
@property (nonatomic, assign) float cpu;
@property (nonatomic, assign) float memory;
@property (nonatomic, strong) NSString *command;
@property (nonatomic, strong) NSString *state;
@property (nonatomic, assign) long virtualMemory;
@property (nonatomic, assign) long residentMemory;
@property (nonatomic, strong) NSString *tty;
@property (nonatomic, strong) NSString *startTime;
@property (nonatomic, strong) NSString *cpuTime;
@property (nonatomic, assign) int threads;
/* Reading it asks the kernel for the high-water mark unless the process list
 * already delivered one; 0 when the system does not report it. */
@property (nonatomic, assign) long peakResidentMemory;
@property (nonatomic, assign) unsigned long long majorFaults;
@property (nonatomic, assign) unsigned long long cpuTicks;
@property (nonatomic, assign) BOOL usesCPUTicks;
@property (nonatomic, assign) unsigned long long startToken;
@property (nonatomic, strong) ProcessHealth *health;

/* Seconds of CPU time from the way "ps" writes its TIME column:
 * "12.34", "3:07", "1:02:03" or "2-03:04:05".  0 when it cannot be read. */
double ProcessParseCPUTimeSeconds(NSString *text);

/* Parses one line of "ps aux", the last resort when neither /proc nor
 * sysctl is available. */
- (id)initWithPsLine:(NSString *)line;

/* The kernel's state letter in words, e.g. "Sleeping". */
- (NSString *)stateDescription;
/* What the process is worth knowing about: the worst finding if there is one,
 * otherwise the plain state. */
- (NSString *)statusText;
/* Sortable severity, so the table can put the problems on top. */
- (NSInteger)healthLevel;
/* The executable without its path and arguments. */
- (NSString *)displayName;

@end
