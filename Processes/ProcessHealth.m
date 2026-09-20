/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessHealth.h"

#include <math.h>

/* ---------------------------------------------------------------------------
 * Thresholds.  They are deliberately conservative: a verdict that fires on
 * ordinary work teaches the user to ignore the column.
 * ------------------------------------------------------------------------- */

/* Resolution and length of the long history.  Half a minute is fine for
 * judging a growth trend and keeps the per-process cost near 2 KB. */
static const NSTimeInterval kSampleInterval = 30.0;
static const NSUInteger kSampleCapacity = 60;

/* A leak is a climb that never falls back, so both a minimum rate and a
 * maximum drawdown have to hold over a window long enough to rule out the
 * memory a program simply needs while it starts up or opens a document. */
static const NSTimeInterval kLeakMinWindow = 180.0;
static const NSUInteger kLeakMinSamples = 5;
static const double kLeakMinGrowthKB = 20.0 * 1024.0;
static const double kLeakMinRateKBPerMin = 512.0;
static const double kLeakProblemRateKBPerMin = 2048.0;
static const double kLeakProblemGrowthKB = 200.0 * 1024.0;
static const double kLeakMaxDrawdownFraction = 0.25;
/* How much of the minimum rate the most recent part of the window still has
 * to show.  Without this a program that filled its caches once and then
 * settled would be reported as leaking for as long as it runs. */
static const double kLeakRecentRateFraction = 0.5;

/* 100 percent is one core fully busy. */
static const double kBusyCPUPercent = 70.0;
static const double kPeggedCPUPercent = 95.0;
static const NSTimeInterval kBusyWatchSeconds = 60.0;
static const NSTimeInterval kBusyProblemSeconds = 300.0;
static const NSTimeInterval kPeggedProblemSeconds = 180.0;

/* Uninterruptible sleep is normal for the length of a disk access, not for
 * seconds on end. */
static const NSTimeInterval kBlockedWatchSeconds = 10.0;
static const NSTimeInterval kBlockedProblemSeconds = 30.0;

/* Threads that are started and never joined. */
static const NSTimeInterval kThreadMinWindow = 180.0;
static const int kThreadMinGrowth = 20;
static const double kThreadMinFactor = 1.5;

/* Major faults are reads from disk, so a steady stream of them means the
 * machine is out of RAM and this process is paying for it. */
static const double kFaultStormPerSecond = 200.0;
static const NSTimeInterval kFaultStormSeconds = 10.0;

/* A share of the machine large enough that the user should know about it. */
static const double kLargeFootprintShare = 0.25;

/* Issue ranks: the lower the number, the more certain and the more
 * actionable the finding, and the earlier it is shown. */
enum {
    kRankBlocked = 10,
    kRankZombie = 20,
    kRankLeak = 30,
    kRankBusy = 40,
    kRankSwapping = 50,
    kRankThreads = 60,
    kRankFootprint = 70,
    kRankSuspended = 80
};

/* ------------------------------------------------------------------------- */

NSString *ProcessStateDescription(unichar state)
{
    switch (state) {
        case 'R': return @"Running";
        case 'S': return @"Sleeping";
        case 'D': return @"Waiting for I/O";
        case 'I': return @"Idle";
        case 'T': return @"Stopped";
        case 't': return @"Traced";
        case 'W': return @"Paging";
        case 'X': return @"Dead";
        case 'Z': return @"Zombie";
        case 'L': return @"Waiting for locks";
        default: break;
    }
    return [NSString stringWithFormat: @"%C", state];
}

NSString *ProcessFormatMemoryKB(long kb)
{
    if (kb <= 0) {
        return @"-";
    }
    if (kb < 1024) {
        return [NSString stringWithFormat: @"%ld KB", kb];
    }
    if (kb < 1024 * 1024) {
        return [NSString stringWithFormat: @"%.0f MB", (double)kb / 1024.0];
    }
    return [NSString stringWithFormat: @"%.2f GB", (double)kb / (1024.0 * 1024.0)];
}

NSString *ProcessFormatDuration(NSTimeInterval seconds)
{
    if (seconds < 90.0) {
        return [NSString stringWithFormat: @"%.0fs", seconds];
    }
    if (seconds < 3600.0) {
        return [NSString stringWithFormat: @"%.0fm", seconds / 60.0];
    }
    return [NSString stringWithFormat: @"%.0fh %.0fm",
                     floor(seconds / 3600.0),
                     fmod(seconds, 3600.0) / 60.0];
}

/* ------------------------------------------------------------------------- */

@implementation ProcessIssue

@synthesize level = _level;
@synthesize rank = _rank;
@synthesize label = _label;
@synthesize explanation = _explanation;

+ (ProcessIssue *)issueWithLevel:(ProcessHealthLevel)level
                            rank:(NSInteger)rank
                           label:(NSString *)label
                     explanation:(NSString *)explanation
{
    ProcessIssue *issue = [[ProcessIssue alloc] init];
    issue->_level = level;
    issue->_rank = rank;
    issue->_label = label;
    issue->_explanation = explanation;
    return issue;
}

- (NSString *)description
{
    return [NSString stringWithFormat: @"<ProcessIssue %@ (level %ld)>",
                     _label, (long)_level];
}

@end

/* ------------------------------------------------------------------------- */

@implementation ProcessHealth

@synthesize issues = _issues;

+ (ProcessHealth *)healthWithIssues:(NSArray *)issues
{
    ProcessHealth *health = [[ProcessHealth alloc] init];
    health->_issues = [issues copy];
    return health;
}

- (ProcessHealthLevel)level
{
    ProcessHealthLevel level = ProcessHealthLevelOK;
    for (ProcessIssue *issue in _issues) {
        if ([issue level] > level) {
            level = [issue level];
        }
    }
    return level;
}

- (NSString *)summary
{
    if ([_issues count] == 0) {
        return nil;
    }
    NSString *label = [[_issues objectAtIndex: 0] label];
    if ([_issues count] > 1) {
        return [NSString stringWithFormat: @"%@ (+%lu)", label,
                         (unsigned long)([_issues count] - 1)];
    }
    return label;
}

- (NSString *)explanation
{
    if ([_issues count] == 0) {
        return nil;
    }
    NSMutableArray *paragraphs = [NSMutableArray array];
    for (ProcessIssue *issue in _issues) {
        [paragraphs addObject: [issue explanation]];
    }
    return [paragraphs componentsJoinedByString: @"\n\n"];
}

- (NSString *)description
{
    return [NSString stringWithFormat: @"<ProcessHealth %@>",
                     ([self summary] ? [self summary] : @"healthy")];
}

@end

/* ---------------------------------------------------------------------------
 * One tracked process.
 * ------------------------------------------------------------------------- */

typedef struct {
    double time;
    double residentKB;
    double cpu;
    double threads;
} PHSample;

@interface PHTrack : NSObject
{
@public
    unsigned long long token;
    unsigned long round;

    NSTimeInterval firstSeen;
    NSTimeInterval lastSeen;

    long residentKB;
    long peakResidentKB;
    int threads;
    unichar state;
    float cpu;

    /* Cumulative CPU ticks of the previous reading. */
    BOOL hasTicks;
    unsigned long long lastTicks;
    NSTimeInterval lastTicksTime;

    BOOL hasFaults;
    unsigned long long lastFaults;
    NSTimeInterval faultSampleTime;
    double faultRate;
    NSTimeInterval faultRunStart;
    NSTimeInterval faultRunEnd;

    /* Start and end of the current uninterrupted run of a condition; a start
     * of 0 means the condition does not hold right now. */
    NSTimeInterval busyRunStart;
    NSTimeInterval busyRunEnd;
    NSTimeInterval peggedRunStart;
    NSTimeInterval peggedRunEnd;
    NSTimeInterval blockedRunStart;
    NSTimeInterval blockedRunEnd;
    NSTimeInterval stoppedSince;

    PHSample *samples;
    NSUInteger sampleCount;
    NSTimeInterval lastStored;
    double cpuSum;
    NSUInteger cpuCount;
}

- (void)resetWithToken:(unsigned long long)aToken atTime:(NSTimeInterval)now;
- (void)storeSampleAtTime:(NSTimeInterval)now;

@end

@implementation PHTrack

- (void)dealloc
{
    if (samples != NULL) {
        free(samples);
        samples = NULL;
    }
}

- (void)resetWithToken:(unsigned long long)aToken atTime:(NSTimeInterval)now
{
    token = aToken;
    firstSeen = now;
    lastSeen = now;
    residentKB = 0;
    peakResidentKB = 0;
    threads = 0;
    state = 0;
    cpu = 0.0;
    hasTicks = NO;
    lastTicks = 0;
    lastTicksTime = 0.0;
    hasFaults = NO;
    lastFaults = 0;
    faultSampleTime = 0.0;
    faultRate = 0.0;
    faultRunStart = 0.0;
    faultRunEnd = 0.0;
    busyRunStart = 0.0;
    busyRunEnd = 0.0;
    peggedRunStart = 0.0;
    peggedRunEnd = 0.0;
    blockedRunStart = 0.0;
    blockedRunEnd = 0.0;
    stoppedSince = 0.0;
    sampleCount = 0;
    lastStored = 0.0;
    cpuSum = 0.0;
    cpuCount = 0;
}

- (void)storeSampleAtTime:(NSTimeInterval)now
{
    if (samples == NULL) {
        samples = calloc(kSampleCapacity, sizeof(PHSample));
        if (samples == NULL) {
            return;
        }
    }
    if (sampleCount == kSampleCapacity) {
        /* Drop the oldest sample.  Shifting costs a couple of kilobytes per
         * process every half minute, which is cheaper than the bookkeeping a
         * ring buffer would need everywhere else. */
        memmove(samples, samples + 1, (kSampleCapacity - 1) * sizeof(PHSample));
        sampleCount--;
    }
    samples[sampleCount].time = now;
    samples[sampleCount].residentKB = (double)residentKB;
    samples[sampleCount].cpu = (cpuCount > 0) ? (cpuSum / (double)cpuCount) : cpu;
    samples[sampleCount].threads = (double)threads;
    sampleCount++;
    lastStored = now;
    cpuSum = 0.0;
    cpuCount = 0;
}

@end

/* Duration of a run, 0 when the condition does not hold right now. */
static NSTimeInterval PHRunDuration(NSTimeInterval start, NSTimeInterval end)
{
    if (start <= 0.0) {
        return 0.0;
    }
    return end - start;
}

/* ------------------------------------------------------------------------- */

@implementation ProcessHistory

@synthesize totalMemoryKB = _totalMemoryKB;

- (id)init
{
    self = [super init];
    if (self) {
        _tracks = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)beginRound
{
    _round++;
}

- (void)endRound
{
    NSMutableArray *gone = nil;
    for (NSNumber *key in _tracks) {
        PHTrack *track = [_tracks objectForKey: key];
        if (track->round != _round) {
            if (gone == nil) {
                gone = [NSMutableArray array];
            }
            [gone addObject: key];
        }
    }
    if (gone != nil) {
        [_tracks removeObjectsForKeys: gone];
    }
}

- (NSUInteger)trackedProcessCount
{
    return [_tracks count];
}

/* Returns the track for a pid, starting a fresh one when the pid is new or
 * when it belongs to a different process than before. */
- (PHTrack *)_trackForPid:(int)pid
                    token:(unsigned long long)token
                   atTime:(NSTimeInterval)now
{
    NSNumber *key = [NSNumber numberWithInt: pid];
    PHTrack *track = [_tracks objectForKey: key];
    if (track == nil) {
        track = [[PHTrack alloc] init];
        [track resetWithToken: token atTime: now];
        [_tracks setObject: track forKey: key];
    } else if (track->token != token) {
        /* The kernel handed the pid to a new process: everything remembered
         * about the old one would be a lie about this one. */
        [track resetWithToken: token atTime: now];
    }
    return track;
}

- (PHTrack *)_trackForPid:(int)pid
{
    return [_tracks objectForKey: [NSNumber numberWithInt: pid]];
}

- (float)cpuPercentForPid:(int)pid
                    token:(unsigned long long)token
               totalTicks:(unsigned long long)totalTicks
           ticksPerSecond:(long)ticksPerSecond
                   atTime:(NSTimeInterval)now
{
    PHTrack *track = [self _trackForPid: pid token: token atTime: now];
    track->round = _round;

    float percent = 0.0;
    if (track->hasTicks && ticksPerSecond > 0) {
        NSTimeInterval dt = now - track->lastTicksTime;
        if (dt > 0.0 && totalTicks >= track->lastTicks) {
            double seconds = (double)(totalTicks - track->lastTicks) /
                             (double)ticksPerSecond;
            percent = (float)(seconds / dt * 100.0);
            if (percent < 0.0) {
                percent = 0.0;
            }
        }
    }
    track->hasTicks = YES;
    track->lastTicks = totalTicks;
    track->lastTicksTime = now;
    return percent;
}

- (void)notePid:(int)pid
          token:(unsigned long long)token
     residentKB:(long)residentKB
            cpu:(float)cpu
        threads:(int)threads
    majorFaults:(unsigned long long)majorFaults
          state:(unichar)state
         atTime:(NSTimeInterval)now
{
    PHTrack *track = [self _trackForPid: pid token: token atTime: now];
    track->round = _round;
    track->lastSeen = now;
    track->residentKB = residentKB;
    if (residentKB > track->peakResidentKB) {
        track->peakResidentKB = residentKB;
    }
    track->threads = threads;
    track->state = state;
    track->cpu = cpu;
    track->cpuSum += cpu;
    track->cpuCount++;

    if (cpu >= kBusyCPUPercent) {
        if (track->busyRunStart <= 0.0) {
            track->busyRunStart = now;
        }
        track->busyRunEnd = now;
    } else {
        track->busyRunStart = 0.0;
        track->busyRunEnd = 0.0;
    }

    if (cpu >= kPeggedCPUPercent) {
        if (track->peggedRunStart <= 0.0) {
            track->peggedRunStart = now;
        }
        track->peggedRunEnd = now;
    } else {
        track->peggedRunStart = 0.0;
        track->peggedRunEnd = 0.0;
    }

    if (state == 'D') {
        if (track->blockedRunStart <= 0.0) {
            track->blockedRunStart = now;
        }
        track->blockedRunEnd = now;
    } else {
        track->blockedRunStart = 0.0;
        track->blockedRunEnd = 0.0;
    }

    if (state == 'T' || state == 't') {
        if (track->stoppedSince <= 0.0) {
            track->stoppedSince = now;
        }
    } else {
        track->stoppedSince = 0.0;
    }

    if (track->hasFaults && majorFaults >= track->lastFaults &&
        now > track->faultSampleTime) {
        /* The counter is cumulative, so only its difference says anything
         * about what the process is doing right now. */
        double rate = (double)(majorFaults - track->lastFaults) /
                      (now - track->faultSampleTime);
        track->faultRate = rate;
        if (rate >= kFaultStormPerSecond) {
            if (track->faultRunStart <= 0.0) {
                track->faultRunStart = now;
            }
            track->faultRunEnd = now;
        } else {
            track->faultRunStart = 0.0;
            track->faultRunEnd = 0.0;
        }
    }
    track->lastFaults = majorFaults;
    track->faultSampleTime = now;
    track->hasFaults = YES;

    if (track->sampleCount == 0 || (now - track->lastStored) >= kSampleInterval) {
        [track storeSampleAtTime: now];
    }
}

/* --- the rules ---------------------------------------------------------- */

/* Least squares slope of the resident size over a range of stored samples
 * (both ends included), in KB per minute, together with the growth across
 * the range and the largest fall back along the way. */
static BOOL PHMemoryTrendInRange(PHTrack *track, NSUInteger first, NSUInteger last,
                                 double *ratePerMinute, double *growthKB,
                                 double *drawdownKB)
{
    if (track->sampleCount < 2 || last >= track->sampleCount || first >= last) {
        return NO;
    }
    NSUInteger count = last - first + 1;
    double sumT = 0.0, sumY = 0.0;
    NSUInteger i;
    for (i = first; i <= last; i++) {
        sumT += track->samples[i].time;
        sumY += track->samples[i].residentKB;
    }
    double meanT = sumT / (double)count;
    double meanY = sumY / (double)count;
    double covariance = 0.0, variance = 0.0;
    double peak = track->samples[first].residentKB;
    double drawdown = 0.0;
    for (i = first; i <= last; i++) {
        double dt = track->samples[i].time - meanT;
        covariance += dt * (track->samples[i].residentKB - meanY);
        variance += dt * dt;
        if (track->samples[i].residentKB > peak) {
            peak = track->samples[i].residentKB;
        } else if ((peak - track->samples[i].residentKB) > drawdown) {
            drawdown = peak - track->samples[i].residentKB;
        }
    }
    if (variance <= 0.0) {
        return NO;
    }
    *ratePerMinute = covariance / variance * 60.0;
    *growthKB = track->samples[last].residentKB - track->samples[first].residentKB;
    *drawdownKB = drawdown;
    return YES;
}

static BOOL PHMemoryTrend(PHTrack *track, double *ratePerMinute,
                          double *growthKB, double *drawdownKB)
{
    if (track->sampleCount < 2) {
        return NO;
    }
    return PHMemoryTrendInRange(track, 0, track->sampleCount - 1,
                                ratePerMinute, growthKB, drawdownKB);
}

- (ProcessIssue *)_leakIssueForTrack:(PHTrack *)track
{
    if (track->sampleCount < kLeakMinSamples) {
        return nil;
    }
    NSTimeInterval window = track->samples[track->sampleCount - 1].time -
                            track->samples[0].time;
    if (window < kLeakMinWindow) {
        return nil;
    }
    double rate = 0.0, growth = 0.0, drawdown = 0.0;
    if (!PHMemoryTrend(track, &rate, &growth, &drawdown)) {
        return nil;
    }
    if (rate < kLeakMinRateKBPerMin || growth < kLeakMinGrowthKB) {
        return nil;
    }
    /* Memory that is handed back now and then is a cache or a busy heap, not
     * a leak. */
    if (drawdown > growth * kLeakMaxDrawdownFraction) {
        return nil;
    }
    /* Growth that has stopped is not a leak either.  A program that filled
     * its caches while it started, or loaded a large document once, keeps a
     * rising slope over the whole window long after it has settled, so the
     * most recent part of the window has to be climbing too. */
    NSUInteger recentCount = track->sampleCount / 3;
    if (recentCount < 2) {
        recentCount = 2;
    }
    double recentRate = 0.0, recentGrowth = 0.0, recentDrawdown = 0.0;
    if (!PHMemoryTrendInRange(track, track->sampleCount - recentCount,
                              track->sampleCount - 1, &recentRate,
                              &recentGrowth, &recentDrawdown)) {
        return nil;
    }
    if (recentRate < kLeakMinRateKBPerMin * kLeakRecentRateFraction) {
        return nil;
    }

    ProcessHealthLevel level = ProcessHealthLevelWatch;
    if (rate >= kLeakProblemRateKBPerMin || growth >= kLeakProblemGrowthKB) {
        level = ProcessHealthLevelProblem;
    }
    NSString *label = [NSString stringWithFormat: @"Memory +%.1f MB/min",
                                rate / 1024.0];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Resident memory grew by %@ over the last %@ (%.1f MB/min) and "
             "never fell back. Memory that only ever grows is the usual sign "
             "of a leak; quitting and reopening the program gives it back.",
            ProcessFormatMemoryKB((long)growth),
            ProcessFormatDuration(window),
            rate / 1024.0];
    return [ProcessIssue issueWithLevel: level
                                   rank: kRankLeak
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_busyCPUIssueForTrack:(PHTrack *)track
{
    NSTimeInterval busy = PHRunDuration(track->busyRunStart, track->busyRunEnd);
    if (busy < kBusyWatchSeconds) {
        return nil;
    }
    NSTimeInterval pegged = PHRunDuration(track->peggedRunStart,
                                          track->peggedRunEnd);
    ProcessHealthLevel level = ProcessHealthLevelWatch;
    if (busy >= kBusyProblemSeconds || pegged >= kPeggedProblemSeconds) {
        level = ProcessHealthLevelProblem;
    }
    NSString *label = [NSString stringWithFormat: @"CPU %.0f%% for %@",
                                (double)track->cpu,
                                ProcessFormatDuration(busy)];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Has been using at least %.0f%% of a processor core without a "
             "break for %@, currently %.0f%%. If the program has nothing to "
             "compute, it is most likely spinning in a loop.",
            kBusyCPUPercent, ProcessFormatDuration(busy), (double)track->cpu];
    return [ProcessIssue issueWithLevel: level
                                   rank: kRankBusy
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_blockedIssueForTrack:(PHTrack *)track
{
    NSTimeInterval blocked = PHRunDuration(track->blockedRunStart,
                                           track->blockedRunEnd);
    if (blocked < kBlockedWatchSeconds) {
        return nil;
    }
    ProcessHealthLevel level = (blocked >= kBlockedProblemSeconds)
                                   ? ProcessHealthLevelProblem
                                   : ProcessHealthLevelWatch;
    NSString *label = [NSString stringWithFormat: @"Blocked on I/O %@",
                                ProcessFormatDuration(blocked)];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Waiting uninterruptibly for %@, which normally means a disk or "
             "a network mount is not answering. A process in this state "
             "ignores every signal, so it cannot be quit until the wait ends; "
             "check the storage it uses.",
            ProcessFormatDuration(blocked)];
    return [ProcessIssue issueWithLevel: level
                                   rank: kRankBlocked
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_zombieIssueForTrack:(PHTrack *)track
{
    if (track->state != 'Z') {
        return nil;
    }
    return [ProcessIssue issueWithLevel: ProcessHealthLevelProblem
                                   rank: kRankZombie
                                  label: @"Zombie"
                            explanation:
        @"Has exited, but the program that started it never collected its "
         "exit status, so it keeps a slot in the process table. Killing it "
         "has no effect: quitting its parent is what clears it."];
}

- (ProcessIssue *)_suspendedIssueForTrack:(PHTrack *)track
{
    if (track->stoppedSince <= 0.0) {
        return nil;
    }
    NSTimeInterval stopped = track->lastSeen - track->stoppedSince;
    NSString *label = [NSString stringWithFormat: @"Suspended %@",
                                ProcessFormatDuration(stopped)];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Stopped by a signal %@ ago and not running at all. It will do "
             "nothing until it is resumed.",
            ProcessFormatDuration(stopped)];
    return [ProcessIssue issueWithLevel: ProcessHealthLevelWatch
                                   rank: kRankSuspended
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_threadIssueForTrack:(PHTrack *)track
{
    if (track->sampleCount < kLeakMinSamples) {
        return nil;
    }
    NSTimeInterval window = track->samples[track->sampleCount - 1].time -
                            track->samples[0].time;
    if (window < kThreadMinWindow) {
        return nil;
    }
    double first = track->samples[0].threads;
    double last = track->samples[track->sampleCount - 1].threads;
    double peak = first;
    NSUInteger i;
    for (i = 0; i < track->sampleCount; i++) {
        if (track->samples[i].threads > peak) {
            peak = track->samples[i].threads;
        }
    }
    if (first <= 0.0 || last < peak) {
        return nil;
    }
    if ((last - first) < (double)kThreadMinGrowth ||
        last < first * kThreadMinFactor) {
        return nil;
    }
    NSString *label = [NSString stringWithFormat: @"Threads +%.0f", last - first];
    NSString *explanation =
        [NSString stringWithFormat:
            @"The thread count climbed from %.0f to %.0f over the last %@ and "
             "never fell back, which points at threads that are started but "
             "never joined.",
            first, last, ProcessFormatDuration(window)];
    return [ProcessIssue issueWithLevel: ProcessHealthLevelWatch
                                   rank: kRankThreads
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_swappingIssueForTrack:(PHTrack *)track
{
    NSTimeInterval storm = PHRunDuration(track->faultRunStart,
                                         track->faultRunEnd);
    if (storm < kFaultStormSeconds) {
        return nil;
    }
    NSString *label = [NSString stringWithFormat: @"Swapping %.0f/s",
                                track->faultRate];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Fetching about %.0f memory pages a second back from disk, and "
             "has been doing so for %@. The machine is short of RAM; this "
             "process spends its time waiting for the disk rather than "
             "working.",
            track->faultRate, ProcessFormatDuration(storm)];
    return [ProcessIssue issueWithLevel: ProcessHealthLevelWatch
                                   rank: kRankSwapping
                                  label: label
                            explanation: explanation];
}

- (ProcessIssue *)_footprintIssueForTrack:(PHTrack *)track
{
    if (_totalMemoryKB <= 0) {
        return nil;
    }
    double share = (double)track->residentKB / (double)_totalMemoryKB;
    if (share < kLargeFootprintShare) {
        return nil;
    }
    NSString *label = [NSString stringWithFormat: @"Large footprint %.0f%%",
                                share * 100.0];
    NSString *explanation =
        [NSString stringWithFormat:
            @"Holds %@ of memory, %.0f%% of everything the machine has. That "
             "is what the rest of the system has to do without.",
            ProcessFormatMemoryKB(track->residentKB), share * 100.0];
    return [ProcessIssue issueWithLevel: ProcessHealthLevelWatch
                                   rank: kRankFootprint
                                  label: label
                            explanation: explanation];
}

- (ProcessHealth *)healthForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    if (track == nil) {
        return nil;
    }

    NSMutableArray *issues = [NSMutableArray array];
    ProcessIssue *candidates[] = {
        [self _blockedIssueForTrack: track],
        [self _zombieIssueForTrack: track],
        [self _leakIssueForTrack: track],
        [self _busyCPUIssueForTrack: track],
        [self _swappingIssueForTrack: track],
        [self _threadIssueForTrack: track],
        [self _footprintIssueForTrack: track],
        [self _suspendedIssueForTrack: track]
    };
    NSUInteger i;
    for (i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (candidates[i] != nil) {
            [issues addObject: candidates[i]];
        }
    }

    /* Worst first, and among equals the most actionable first. */
    [issues sortUsingComparator: ^NSComparisonResult(id a, id b) {
        ProcessIssue *left = a, *right = b;
        if ([left level] != [right level]) {
            return ([left level] > [right level]) ? NSOrderedAscending
                                                  : NSOrderedDescending;
        }
        if ([left rank] != [right rank]) {
            return ([left rank] < [right rank]) ? NSOrderedAscending
                                                : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    return [ProcessHealth healthWithIssues: issues];
}

/* --- detail for the inspector ------------------------------------------- */

- (NSArray *)residentMBSamplesForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    NSMutableArray *values = [NSMutableArray array];
    if (track == nil) {
        return values;
    }
    NSUInteger i;
    for (i = 0; i < track->sampleCount; i++) {
        [values addObject: [NSNumber numberWithDouble:
                               track->samples[i].residentKB / 1024.0]];
    }
    return values;
}

- (NSArray *)cpuSamplesForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    NSMutableArray *values = [NSMutableArray array];
    if (track == nil) {
        return values;
    }
    NSUInteger i;
    for (i = 0; i < track->sampleCount; i++) {
        [values addObject: [NSNumber numberWithDouble: track->samples[i].cpu]];
    }
    return values;
}

- (double)memoryGrowthMBPerMinuteForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    if (track == nil) {
        return 0.0;
    }
    double rate = 0.0, growth = 0.0, drawdown = 0.0;
    if (!PHMemoryTrend(track, &rate, &growth, &drawdown)) {
        return 0.0;
    }
    return rate / 1024.0;
}

- (NSTimeInterval)highCPUDurationForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    if (track == nil) {
        return 0.0;
    }
    return PHRunDuration(track->busyRunStart, track->busyRunEnd);
}

- (long)peakResidentKBForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    return (track != nil) ? track->peakResidentKB : 0;
}

- (NSTimeInterval)observedDurationForPid:(int)pid
{
    PHTrack *track = [self _trackForPid: pid];
    if (track == nil) {
        return 0.0;
    }
    return track->lastSeen - track->firstSeen;
}

@end
