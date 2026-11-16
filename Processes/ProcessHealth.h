/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* How much attention a process deserves.  The order matters: the numbers are
 * compared and sorted on. */
typedef enum {
    ProcessHealthLevelOK = 0,
    ProcessHealthLevelWatch = 1,
    ProcessHealthLevelProblem = 2
} ProcessHealthLevel;

/* "Sleeping", "Waiting for I/O", ... for the single-letter process state the
 * kernel reports. */
NSString *ProcessStateDescription(unichar state);

/* "88 MB", "1.20 GB". */
NSString *ProcessFormatMemoryKB(long kb);

/* "45s", "6m", "2h 10m". */
NSString *ProcessFormatDuration(NSTimeInterval seconds);

/* One thing that looks wrong with a process. */
@interface ProcessIssue : NSObject
{
    ProcessHealthLevel _level;
    NSInteger _rank;
    NSString *_label;
    NSString *_explanation;
}

@property (nonatomic, readonly) ProcessHealthLevel level;
/* Sorts issues of equal level; lower means more actionable. */
@property (nonatomic, readonly) NSInteger rank;
/* Short enough for a table column, e.g. "Memory +18 MB/min". */
@property (nonatomic, readonly) NSString *label;
/* Full sentences: what was measured and what the user can do about it. */
@property (nonatomic, readonly) NSString *explanation;

+ (ProcessIssue *)issueWithLevel:(ProcessHealthLevel)level
                            rank:(NSInteger)rank
                           label:(NSString *)label
                     explanation:(NSString *)explanation;

@end

/* The verdict on one process: everything that looks wrong with it, worst
 * first. */
@interface ProcessHealth : NSObject
{
    NSArray *_issues;
}

@property (nonatomic, readonly) NSArray *issues;
@property (nonatomic, readonly) ProcessHealthLevel level;
/* Label of the worst issue, with " (+n)" when there are more.  nil when the
 * process looks healthy. */
@property (nonatomic, readonly) NSString *summary;
/* All explanations, one per paragraph.  nil when the process looks healthy. */
@property (nonatomic, readonly) NSString *explanation;

+ (ProcessHealth *)healthWithIssues:(NSArray *)issues;

@end

/* Remembers what every process did over the last half hour and derives the
 * verdicts from it.  One instance per application; all of its state is keyed
 * by pid plus a start token, so a reused pid starts with a clean history.
 *
 * Every refresh calls -beginRound, then -cpuPercentForPid:... and -notePid:...
 * once per live process, then -endRound, which forgets the processes that are
 * gone.
 */
@interface ProcessHistory : NSObject
{
    NSMutableDictionary *_tracks;
    long _totalMemoryKB;
    unsigned long _round;
}

/* Needed for the "holds a large share of the machine" verdict. */
@property (nonatomic, assign) long totalMemoryKB;

- (void)beginRound;
- (void)endRound;

/* CPU percentage from the difference between two cumulative tick readings.
 * 100 means one core fully busy.  The first reading of a process yields 0. */
- (float)cpuPercentForPid:(int)pid
                    token:(unsigned long long)token
               totalTicks:(unsigned long long)totalTicks
           ticksPerSecond:(long)ticksPerSecond
                   atTime:(NSTimeInterval)now;

- (void)notePid:(int)pid
          token:(unsigned long long)token
     residentKB:(long)residentKB
            cpu:(float)cpu
        threads:(int)threads
    majorFaults:(unsigned long long)majorFaults
          state:(unichar)state
         atTime:(NSTimeInterval)now;

- (ProcessHealth *)healthForPid:(int)pid;

/* Detail for the inspector, oldest sample first. */
- (NSArray *)residentMBSamplesForPid:(int)pid;
- (NSArray *)cpuSamplesForPid:(int)pid;
- (double)memoryGrowthMBPerMinuteForPid:(int)pid;
- (NSTimeInterval)highCPUDurationForPid:(int)pid;
- (long)peakResidentKBForPid:(int)pid;
- (NSTimeInterval)observedDurationForPid:(int)pid;
- (NSUInteger)trackedProcessCount;

@end
