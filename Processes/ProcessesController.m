/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessesController.h"
#import <dirent.h>
#import <pwd.h>
#import <sys/stat.h>
#include <stdint.h>
#ifndef __linux__
#import <sys/sysctl.h>
#if __has_include(<sys/user.h>)
#import <sys/user.h>
#endif
#endif
#import <unistd.h>
#import <signal.h>

/* Kernel processes are flagged P_SYSTEM, but the value differs between the
 * BSDs, so it is only used where the system headers define it.  Guessing it
 * would either hide real processes or list the kernel's own. */
#ifdef P_SYSTEM
#define PROCESSES_IS_KERNEL(flag) (((flag) & P_SYSTEM) != 0)
#else
#define PROCESSES_IS_KERNEL(flag) (0)
#endif

// OpenBSD struct kinfo_proc uses p_ prefix instead of ki_.  Map to ki_ names
// so the shared code path compiles on both FreeBSD and OpenBSD.
#ifdef __OpenBSD__
#define ki_flag p_flag
#define ki_pid p_pid
#define ki_ppid p_ppid
#define ki_comm p_comm
#define ki_uid p_uid
#define ki_stat p_stat
#define ki_rssize p_vm_rssize
// OpenBSD does not have p_vm_dsize/p_vm_ssize; handled via #ifdef at use site.
#endif

#import <errno.h>
#import <sys/wait.h>
#import <string.h>

// Simple logging macro for this module
// Logging macros: PC_INFO is always enabled; PC_DBG is enabled only when PROCESSES_DEBUG is set to 1
#ifndef PROCESSES_DEBUG
#define PROCESSES_DEBUG 0
#endif

#ifndef PC_INFO
#define PC_INFO(fmt, ...) NSDebugLLog(@"gwcomp", (@"[Processes] " fmt), ##__VA_ARGS__)
#endif

#ifndef PC_DBG
#if PROCESSES_DEBUG
#define PC_DBG(fmt, ...) NSDebugLLog(@"gwcomp", (@"[Processes] " fmt), ##__VA_ARGS__)
#else
#define PC_DBG(fmt, ...) ((void)0)
#endif
#endif

/* Reading every process is not free, so a scan that takes longer than this is
 * cut short rather than pegging a core. */
static const double kMaxScanSeconds = 3.0;

/* The inspector drawer. */
static const CGFloat kDrawerWidth = 320.0;
static const CGFloat kDrawerHeight = 480.0;
static const CGFloat kSparklineHeight = 54.0;

/* NSTableView subclass that draws full-row alternating backgrounds (no
 * per-cell gaps) and lets a right-click act on the row under the pointer. */
@interface ProcessTableView : NSTableView
@end

@implementation ProcessTableView

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clipRect
{
    NSRect rowRect = [self rectOfRow:row];

    if ([self isRowSelected:row]) {
        [[NSColor selectedControlColor] setFill];
    } else if (row % 2 == 0) {
        [[NSColor controlBackgroundColor] setFill];
    } else {
        [[NSColor colorWithCalibratedWhite:0.93 alpha:1.0] setFill];
    }
    NSRectFill(rowRect);

    [super drawRow:row clipRect:clipRect];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    /* Without this the context menu would act on whatever was selected
     * before, not on the row the user aimed at. */
    NSPoint where = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger row = [self rowAtPoint:where];
    if (row >= 0) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
          byExtendingSelection:NO];
    }
    return [super menuForEvent:event];
}

@end

// Helper function to get total system memory in KB
static long getTotalSystemMemoryKB(void) {
    long totalMemory = 0;

#ifdef __linux__
    // Linux: Read from /proc/meminfo
    FILE *memFile = fopen("/proc/meminfo", "r");
    if (memFile) {
        char line[256];
        while (fgets(line, sizeof(line), memFile)) {
            if (strncmp(line, "MemTotal:", 9) == 0) {
                sscanf(line, "MemTotal: %ld", &totalMemory);
                break;
            }
        }
        fclose(memFile);
    }
#else
    // BSD and other Unix-like systems: prefer sysctlbyname for portability
    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
#if defined(__OpenBSD__)
    // OpenBSD has no sysctlbyname(); read physical memory via the numeric mib.
#ifdef HW_PHYSMEM64
    int mib[2] = {CTL_HW, HW_PHYSMEM64};
    len = sizeof(memsize);
    if (sysctl(mib, 2, &memsize, &len, NULL, 0) == 0) {
        totalMemory = (long)(memsize / 1024);
    }
#endif
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
    // Try several common sysctl names across BSDs/macOS
    const char *names[] = { "hw.memsize", "hw.physmem", "hw.realmem", "hw.physmem64", NULL };
    const char **n;
    for (n = names; *n != NULL; n++) {
        len = sizeof(memsize);
        if (sysctlbyname(*n, &memsize, &len, NULL, 0) == 0 && len > 0) {
            totalMemory = (long)(memsize / 1024);
            break;
        }
    }
    if (totalMemory == 0) {
#ifdef HW_MEMSIZE
        int mib[2] = {CTL_HW, HW_MEMSIZE};
        len = sizeof(memsize);
        if (sysctl(mib, 2, &memsize, &len, NULL, 0) == 0) {
            totalMemory = (long)(memsize / 1024);
        }
#endif
    }
#else
#ifdef HW_MEMSIZE
    int mib[2] = {CTL_HW, HW_MEMSIZE};
    unsigned long memsize_ul = 0;
    size_t len_ul = sizeof(memsize_ul);
    if (sysctl(mib, 2, &memsize_ul, &len_ul, NULL, 0) == 0) {
        totalMemory = memsize_ul / 1024;
    }
#endif
#endif
#endif

    return totalMemory;
}

/* Resolving a uid hits the name service, so the handful of distinct owners in
 * a process list are looked up once per scan. */
static NSString *userNameForUid(uid_t uid, NSMutableDictionary *cache)
{
    NSNumber *key = [NSNumber numberWithUnsignedInt:(unsigned int)uid];
    NSString *name = [cache objectForKey:key];
    if (name == nil) {
        struct passwd *pw = getpwuid(uid);
        if (pw != NULL && pw->pw_name != NULL) {
            name = [NSString stringWithUTF8String:pw->pw_name];
        } else {
            name = [NSString stringWithFormat:@"%u", (unsigned int)uid];
        }
        [cache setObject:name forKey:key];
    }
    return name;
}

/* --------------------------------------------------------------------------
 * The three ways to read the process list.  Each one fills "out" with
 * ProcessInfo objects carrying raw readings; the percentages and the verdicts
 * are derived later, in one place.
 * ------------------------------------------------------------------------ */

/* Reads /proc.  Returns NO when there is no /proc to read.  *truncated is set
 * when the scan was cut short, in which case the list is incomplete. */
static BOOL scanProcFilesystem(NSMutableArray *out, BOOL *truncated)
{
    DIR *procDir = opendir("/proc");
    if (procDir == NULL) {
        return NO;
    }

    NSMutableDictionary *userCache = [NSMutableDictionary dictionary];
    long pageSizeKB = sysconf(_SC_PAGESIZE) / 1024;
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
    struct dirent *entry;

    while ((entry = readdir(procDir)) != NULL) {
        if (([NSDate timeIntervalSinceReferenceDate] - startTime) > kMaxScanSeconds) {
            *truncated = YES;
            break;
        }

        char *endptr;
        int pid = (int)strtol(entry->d_name, &endptr, 10);
        if (*endptr != '\0' || pid <= 0) {
            continue;
        }

        char statPath[256];
        snprintf(statPath, sizeof(statPath), "/proc/%d/stat", pid);
        FILE *statFile = fopen(statPath, "r");
        if (statFile == NULL) {
            continue;
        }
        char statLine[1024];
        if (fgets(statLine, sizeof(statLine), statFile) == NULL) {
            fclose(statFile);
            continue;
        }
        fclose(statFile);

        /* The executable name is in parentheses and may itself contain spaces
         * and parentheses, so the fixed fields start after the LAST one. */
        char *lparen = strchr(statLine, '(');
        char *rparen = strrchr(statLine, ')');
        if (lparen == NULL || rparen == NULL || rparen <= lparen) {
            continue;
        }
        char comm[256];
        size_t commLength = (size_t)(rparen - lparen - 1);
        if (commLength >= sizeof(comm)) {
            commLength = sizeof(comm) - 1;
        }
        memcpy(comm, lparen + 1, commLength);
        comm[commLength] = '\0';

        /* Field numbers counted from the state, which is the first field
         * after the closing parenthesis (proc(5) field 3). */
        char stateChar = '?';
        int ppid = 0, threads = 0;
        unsigned long long majorFaults = 0, utime = 0, stime = 0, startTicks = 0;
        unsigned long vsizeBytes = 0;
        long rssPages = 0;
        char *saveptr = NULL;
        char *token = strtok_r(rparen + 2, " ", &saveptr);
        int field = 1;
        while (token != NULL) {
            switch (field) {
                case 1: stateChar = token[0]; break;
                case 2: ppid = atoi(token); break;
                case 10: majorFaults = strtoull(token, NULL, 10); break;
                case 12: utime = strtoull(token, NULL, 10); break;
                case 13: stime = strtoull(token, NULL, 10); break;
                case 18: threads = atoi(token); break;
                case 20: startTicks = strtoull(token, NULL, 10); break;
                case 21: vsizeBytes = strtoul(token, NULL, 10); break;
                case 22: rssPages = atol(token); break;
                default: break;
            }
            if (field >= 22) {
                break;
            }
            token = strtok_r(NULL, " ", &saveptr);
            field++;
        }

        ProcessInfo *info = [[ProcessInfo alloc] init];
        info.pid = pid;
        info.ppid = ppid;
        info.state = [NSString stringWithFormat:@"%c", stateChar];
        info.threads = threads;
        info.majorFaults = majorFaults;
        info.startToken = startTicks;
        info.cpuTicks = utime + stime;
        info.usesCPUTicks = YES;
        info.virtualMemory = (long)(vsizeBytes / 1024);
        info.residentMemory = rssPages * pageSizeKB;

        /* Kernel threads have no command line; they are the kernel's business,
         * not the user's.  A zombie has none either, and it is exactly what
         * the user needs to see, so it is kept. */
        BOOL hasCmdline = NO;
        char cmdPath[256];
        snprintf(cmdPath, sizeof(cmdPath), "/proc/%d/cmdline", pid);
        FILE *cmdFile = fopen(cmdPath, "r");
        if (cmdFile != NULL) {
            char cmdLine[1024];
            size_t length = fread(cmdLine, 1, sizeof(cmdLine) - 1, cmdFile);
            if (length > 0) {
                hasCmdline = YES;
                cmdLine[length] = '\0';
                size_t i;
                for (i = 0; i < length; i++) {
                    if (cmdLine[i] == '\0') {
                        cmdLine[i] = ' ';
                    }
                }
                info.command = [NSString stringWithUTF8String:cmdLine];
            }
            fclose(cmdFile);
        }
        if (!hasCmdline && stateChar != 'Z') {
            continue;
        }
        if ([info.command length] == 0) {
            info.command = [NSString stringWithUTF8String:comm];
        }

        /* The owner of the /proc entry is the owner of the process, which is
         * one stat() instead of reading another file. */
        char procPath[64];
        snprintf(procPath, sizeof(procPath), "/proc/%d", pid);
        struct stat procStat;
        if (stat(procPath, &procStat) == 0) {
            info.user = userNameForUid(procStat.st_uid, userCache);
        } else {
            info.user = @"unknown";
        }

        [out addObject:info];
    }

    closedir(procDir);
    return YES;
}

/* Reads the process list through sysctl, the way the BSDs expose it.  Returns
 * NO where that interface does not exist. */
static BOOL scanSysctl(NSMutableArray *out)
{
/* Only the BSDs whose kinfo_proc field names are known are read this way:
 * every BSD spells them differently, and wrong names would compile into
 * wrong numbers instead of failing.  Everything else falls to "ps" below. */
#if (defined(__FreeBSD__) || defined(__OpenBSD__)) && defined(CTL_KERN) && \
    defined(KERN_PROC) && defined(KERN_PROC_ALL) && __has_include(<sys/user.h>)
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0 || length == 0) {
        PC_INFO(@"sysctl could not size the process list");
        return NO;
    }
    struct kinfo_proc *procs = malloc(length);
    if (procs == NULL) {
        PC_INFO(@"out of memory for the process list");
        return NO;
    }
    if (sysctl(mib, 4, procs, &length, NULL, 0) != 0) {
        PC_INFO(@"sysctl could not read the process list");
        free(procs);
        return NO;
    }

    NSMutableDictionary *userCache = [NSMutableDictionary dictionary];
    long pageSizeKB = sysconf(_SC_PAGESIZE) / 1024;
    long ticksPerSecond = sysconf(_SC_CLK_TCK);
#ifdef __OpenBSD__
    (void)ticksPerSecond;   /* OpenBSD reports CPU ticks directly */
#endif
    int count = (int)(length / sizeof(struct kinfo_proc));
    int i;
    for (i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        if (PROCESSES_IS_KERNEL(p->ki_flag)) {
            continue;
        }
        ProcessInfo *info = [[ProcessInfo alloc] init];
        info.pid = p->ki_pid;
        info.ppid = p->ki_ppid;
        info.command = (p->ki_comm[0] != '\0')
                           ? [NSString stringWithUTF8String:p->ki_comm]
                           : @"";
        info.user = userNameForUid(p->ki_uid, userCache);
        info.residentMemory = (long)p->ki_rssize * pageSizeKB;

        char stateChar;
        switch (p->ki_stat) {
#ifdef __OpenBSD__
            // OpenBSD does not expose state constants in userspace;
            // use numeric values: 2=SRUN, 3=SSLEEP, 4=SSTOP, 5=SZOMB
            case 5: stateChar = 'Z'; break;
            case 4: stateChar = 'T'; break;
            case 2: stateChar = 'R'; break;
            case 3: stateChar = 'S'; break;
            default: stateChar = 'R'; break;
#else
            case SZOMB: stateChar = 'Z'; break;
            case SSTOP: stateChar = 'T'; break;
            case SRUN: stateChar = 'R'; break;
            case SSLEEP: stateChar = 'S'; break;
            default: stateChar = 'R'; break;
#endif
        }
        info.state = [NSString stringWithFormat:@"%c", stateChar];

#ifdef __OpenBSD__
        info.virtualMemory = 0;
        info.startToken = (unsigned long long)p->p_ustart_sec;
        info.threads = 0;
        info.majorFaults = 0;
        info.peakResidentMemory = (long)p->p_uru_maxrss;
        unsigned long long ticks = (unsigned long long)p->p_uticks +
                                   (unsigned long long)p->p_sticks;
#else
        info.virtualMemory = (long)(p->ki_size / 1024);
        info.startToken = (unsigned long long)p->ki_start.tv_sec;
        info.threads = p->ki_numthreads;
        info.majorFaults = (unsigned long long)p->ki_rusage.ru_majflt;
        /* ru_maxrss is the high-water mark over the whole life of the
         * process, which is what the inspector reports as the peak. */
        info.peakResidentMemory = (long)p->ki_rusage.ru_maxrss;
        unsigned long long ticks =
            (unsigned long long)(p->ki_rusage.ru_utime.tv_sec * ticksPerSecond +
                                 p->ki_rusage.ru_utime.tv_usec * ticksPerSecond / 1000000) +
            (unsigned long long)(p->ki_rusage.ru_stime.tv_sec * ticksPerSecond +
                                 p->ki_rusage.ru_stime.tv_usec * ticksPerSecond / 1000000);
#endif
        info.cpuTicks = ticks;
        info.usesCPUTicks = YES;

        [out addObject:info];
    }
    free(procs);
    return YES;
#else
    (void)out;
    return NO;
#endif
}

/* The last resort, and the only path on a system without /proc whose
 * kinfo_proc we do not know: whatever "ps" can tell us.  Memory, state,
 * owner, command and - through the cumulative CPU time it prints - the
 * current CPU load all come through; thread count, page faults and the
 * kernel's memory high-water mark do not, so the findings that need those
 * simply never fire there. */
static BOOL scanPsAux(NSMutableArray *out)
{
    FILE *ps = popen("LC_ALL=C ps aux", "r");
    if (ps == NULL) {
        PC_INFO(@"ps aux could not be started");
        return NO;
    }
    char line[2048];
    if (fgets(line, sizeof(line), ps) == NULL) {   // header
        pclose(ps);
        return NO;
    }
    while (fgets(line, sizeof(line), ps)) {
        size_t length = strlen(line);
        if (length > 0 && line[length - 1] == '\n') {
            line[length - 1] = '\0';
        }
        @autoreleasepool {
            NSString *text = [NSString stringWithUTF8String:line];
            ProcessInfo *info = [[ProcessInfo alloc] initWithPsLine:text];
            if (info != nil && info.pid > 0 && ![info.command hasPrefix:@"["]) {
                [out addObject:info];
            }
        }
    }
    pclose(ps);
    return YES;
}

/* --------------------------------------------------------------------------
 * Appearance of a verdict.
 * ------------------------------------------------------------------------ */

static NSColor *levelTextColor(NSInteger level)
{
    if (level >= ProcessHealthLevelProblem) {
        return [NSColor colorWithCalibratedRed:0.62 green:0.05 blue:0.05 alpha:1.0];
    }
    if (level >= ProcessHealthLevelWatch) {
        return [NSColor colorWithCalibratedRed:0.60 green:0.34 blue:0.0 alpha:1.0];
    }
    return [NSColor controlTextColor];
}

/* A dot in the leftmost column, so a problem is visible without reading. */
static NSImage *levelImage(NSInteger level)
{
    static NSImage *problemDot = nil;
    static NSImage *watchDot = nil;

    if (level < ProcessHealthLevelWatch) {
        return nil;
    }
    BOOL problem = (level >= ProcessHealthLevelProblem);
    if (problem && problemDot != nil) {
        return problemDot;
    }
    if (!problem && watchDot != nil) {
        return watchDot;
    }

    NSColor *color = problem
        ? [NSColor colorWithCalibratedRed:0.80 green:0.10 blue:0.10 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.95 green:0.65 blue:0.10 alpha:1.0];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(10.0, 10.0)];
    [image lockFocus];
    NSBezierPath *circle =
        [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1.0, 1.0, 8.0, 8.0)];
    [color setFill];
    [circle fill];
    [[NSColor colorWithCalibratedWhite:0.25 alpha:0.6] setStroke];
    [circle setLineWidth:0.5];
    [circle stroke];
    [image unlockFocus];

    if (problem) {
        problemDot = image;
    } else {
        watchDot = image;
    }
    return image;
}

/* The drawer's content view.  The drawer resizes it to whatever height the
 * window leaves, so the layout is recomputed rather than autoresized. */
@interface ProcessesDrawerView : NSView
{
    /* The controller outlives every view it owns. */
    __unsafe_unretained ProcessesController *_layoutOwner;
}
- (void)setLayoutOwner:(ProcessesController *)owner;
@end

@implementation ProcessesDrawerView

- (void)setLayoutOwner:(ProcessesController *)owner
{
    _layoutOwner = owner;
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [_layoutOwner layoutDrawerContent];
}

/* The drawer's box sets the frame directly, which does not go through
 * -setFrameSize:. */
- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    [_layoutOwner layoutDrawerContent];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [_layoutOwner layoutDrawerContent];
}

@end

/* ------------------------------------------------------------------------ */

@implementation ProcessesController

@synthesize processes = _processes;

static ProcessesController *sharedController = nil;

+ (ProcessesController *)sharedController
{
    if (!sharedController) {
        sharedController = [[ProcessesController alloc] init];
    }
    return sharedController;
}

- (id)init
{
    self = [super init];
    if (self) {
        _processes = [[NSMutableArray alloc] init];
        _visibleProcesses = [NSArray array];
        _processesLock = [[NSLock alloc] init];
        _refreshInterval = 5.0; // Refresh every 5 seconds
        _history = [[ProcessHistory alloc] init];
        _totalMemoryKB = getTotalSystemMemoryKB();
        [_history setTotalMemoryKB:_totalMemoryKB];
        _searchFilter = @"";
    }
    return self;
}

- (void)dealloc
{
    // Cleanup not involving object releases (ARC handles memory)
    [self stopMonitoring];
    // Other cleanup if necessary
}

- (void)awakeFromNib
{
    // Not using nib
}

- (void)startMonitoring
{
    if (!_refreshTimer) {
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:_refreshInterval
                                                          target:self
                                                        selector:@selector(refreshProcesses)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

- (void)stopMonitoring
{
    if (_refreshTimer) {
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
}

- (BOOL)isRefreshing
{
    return _isRefreshing;
}

- (void)refreshProcesses
{
    // Don't re-enter a refresh if one is already running
    if (_isRefreshing) {
        return;
    }
    _isRefreshing = YES;
    PC_DBG(@"refreshProcesses entered");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *newProcesses = [[NSMutableArray alloc] init];
        BOOL truncated = NO;

        if (!scanProcFilesystem(newProcesses, &truncated)) {
            PC_DBG(@"no /proc, asking sysctl");
            scanSysctl(newProcesses);
        } else if ([newProcesses count] == 0) {
            PC_INFO(@"/proc yielded no processes, asking sysctl");
            scanSysctl(newProcesses);
        }
        if ([newProcesses count] == 0) {
            PC_INFO(@"falling back to parsing ps aux");
            scanPsAux(newProcesses);
        }
        PC_DBG(@"scanned %lu processes%@", (unsigned long)[newProcesses count],
               truncated ? @" (cut short)" : @"");

        NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
            newProcesses, @"new",
            [NSNumber numberWithBool:truncated], @"truncated", nil];

        // Apply results on main thread (or directly if app not running)
        if ([NSApp isRunning]) {
            [self performSelectorOnMainThread:@selector(_applyResultsOnMainThread:)
                                   withObject:payload
                                waitUntilDone:NO];
        } else {
            [self _applyResultsOnMainThread:payload];
        }
    });
}

/* Turns the raw readings into percentages and verdicts.  Everything that
 * needs the previous round lives here, on one thread, so the history needs no
 * locking of its own. */
- (void)_applyResultsOnMainThread:(NSDictionary *)payload
{
    NSArray *newProcesses = [payload objectForKey:@"new"];
    BOOL truncated = [[payload objectForKey:@"truncated"] boolValue];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    long ticksPerSecond = sysconf(_SC_CLK_TCK);

    [_history beginRound];
    for (ProcessInfo *info in newProcesses) {
        if (info.usesCPUTicks) {
            info.cpu = [_history cpuPercentForPid:info.pid
                                            token:info.startToken
                                       totalTicks:info.cpuTicks
                                   ticksPerSecond:ticksPerSecond
                                           atTime:now];
        }
        if (_totalMemoryKB > 0) {
            info.memory = (float)(info.residentMemory * 100.0 / _totalMemoryKB);
        }
        [_history notePid:info.pid
                    token:info.startToken
               residentKB:info.residentMemory
                      cpu:info.cpu
                  threads:info.threads
              majorFaults:info.majorFaults
                    state:([info.state length] > 0
                               ? [info.state characterAtIndex:0] : '?')
                   atTime:now];
        info.health = [_history healthForPid:info.pid];
    }
    /* A scan that was cut short has not seen every process, so forgetting the
     * ones it missed would throw away their history. */
    if (!truncated) {
        [_history endRound];
    }

    [_processesLock lock];
    [_processes removeAllObjects];
    [_processes addObjectsFromArray:newProcesses];
    [_processesLock unlock];

    [self sortProcesses];
    if (_infoDrawer != nil && [_infoDrawer state] != NSDrawerClosedState) {
        [self updateInfoDrawer];
    }
    PC_DBG(@"applied %lu processes", (unsigned long)[_processes count]);

    _isRefreshing = NO;
}

/* --- what the table shows ---------------------------------------------- */

- (void)updateVisibleProcesses
{
    /* Read before the list is replaced: the same process should stay
     * selected across a refresh, not whatever moves into its row. */
    ProcessInfo *selected = [self selectedProcess];
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:[_processes count]];
    NSString *filter = ([_searchFilter length] > 0)
                           ? [_searchFilter lowercaseString] : nil;

    for (ProcessInfo *info in _processes) {
        if (_problemsOnly && [info healthLevel] < ProcessHealthLevelWatch) {
            continue;
        }
        if (filter != nil) {
            BOOL matches =
                [[info.command lowercaseString] containsString:filter] ||
                [[info.user lowercaseString] containsString:filter] ||
                [[NSString stringWithFormat:@"%d", info.pid] containsString:filter] ||
                [[[info statusText] lowercaseString] containsString:filter];
            if (!matches) {
                continue;
            }
        }
        [visible addObject:info];
    }

    _visibleProcesses = visible;
    [self updateSummary];

    [_processesTableView reloadData];
    if (selected != nil) {
        NSUInteger index = [_visibleProcesses indexOfObjectIdenticalTo:selected];
        if (index != NSNotFound) {
            [_processesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                            byExtendingSelection:NO];
        }
    }
}

- (void)updateSummary
{
    NSUInteger problems = 0, watches = 0;
    for (ProcessInfo *info in _processes) {
        NSInteger level = [info healthLevel];
        if (level >= ProcessHealthLevelProblem) {
            problems++;
        } else if (level >= ProcessHealthLevelWatch) {
            watches++;
        }
    }

    NSMutableString *text = [NSMutableString string];
    if ([_visibleProcesses count] != [_processes count]) {
        [text appendFormat:@"%lu of %lu processes shown",
                           (unsigned long)[_visibleProcesses count],
                           (unsigned long)[_processes count]];
    } else {
        [text appendFormat:@"%lu processes", (unsigned long)[_processes count]];
    }
    if (problems == 0 && watches == 0) {
        [text appendString:@" - nothing looks wrong"];
    } else {
        [text appendString:@" - "];
        if (problems > 0) {
            [text appendFormat:@"%lu problem%@", (unsigned long)problems,
                               (problems == 1 ? @"" : @"s")];
        }
        if (problems > 0 && watches > 0) {
            [text appendString:@", "];
        }
        if (watches > 0) {
            [text appendFormat:@"%lu worth watching", (unsigned long)watches];
        }
    }

    [_summaryLabel setStringValue:text];
    [_summaryLabel setTextColor:(problems > 0 ? levelTextColor(ProcessHealthLevelProblem)
                                              : [NSColor controlTextColor])];
}

- (ProcessInfo *)selectedProcess
{
    NSInteger row = [_processesTableView selectedRow];
    if (row < 0 || row >= (NSInteger)[_visibleProcesses count]) {
        return nil;
    }
    return [_visibleProcesses objectAtIndex:row];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] != _searchField) {
        return;
    }
    /* While the field is being edited its cell still holds the value from
     * before the keystroke, so the filter has to come from the field editor
     * or it lags one character behind. */
    NSText *editor = [[notification userInfo] objectForKey:@"NSFieldEditor"];
    NSString *text = (editor != nil) ? [editor string] : [_searchField stringValue];
    _searchFilter = (text != nil) ? [text copy] : @"";
    [self updateVisibleProcesses];
}

- (void)clearSearchFilter
{
    _searchFilter = @"";
    [self updateVisibleProcesses];
}

/* The search field's own action fires when Return is pressed and when its
 * cancel button empties it; neither sends a text-did-change notification. */
- (IBAction)searchFieldAction:(id)sender
{
    NSString *text = [_searchField stringValue];
    _searchFilter = (text != nil) ? [text copy] : @"";
    [self updateVisibleProcesses];
}

- (IBAction)toggleProblemsOnly:(id)sender
{
    _problemsOnly = ([_problemsOnlyCheckbox state] == NSOnState);
    [self updateVisibleProcesses];
}

- (IBAction)refreshNow:(id)sender
{
    [self refreshProcesses];
}

/* --- acting on a process ----------------------------------------------- */

/* Sends a signal, asking for the rights when the process belongs to somebody
 * else.  Returns whether the signal went out. */
- (BOOL)sendSignal:(int)signalNumber toProcess:(ProcessInfo *)info
{
    if (info == nil) {
        return NO;
    }
    if (kill(info.pid, signalNumber) == 0) {
        return YES;
    }
    if (errno != EPERM) {
        PC_INFO(@"signal %d to pid %d failed: %s", signalNumber, info.pid,
                strerror(errno));
        return NO;
    }

    char pidString[16];
    char signalString[16];
    snprintf(pidString, sizeof(pidString), "%d", info.pid);
    snprintf(signalString, sizeof(signalString), "-%d", signalNumber);
    pid_t child = fork();
    if (child == 0) {
        execlp("sudo", "sudo", "-A", "-E", "kill", signalString, pidString,
               (char *)NULL);
        _exit(127);
    } else if (child < 0) {
        return NO;
    }
    int status = 0;
    waitpid(child, &status, 0);
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

- (void)actOnSelectionWithSignal:(int)signalNumber
{
    ProcessInfo *info = [self selectedProcess];
    if (info == nil) {
        return;
    }
    [self sendSignal:signalNumber toProcess:info];
    /* Show the result rather than the state from before the signal. */
    [self performSelector:@selector(refreshProcesses) withObject:nil afterDelay:0.5];
}

- (IBAction)quitProcess:(id)sender
{
    [self actOnSelectionWithSignal:SIGTERM];
}

- (IBAction)forceQuitProcess:(id)sender
{
    ProcessInfo *info = [self selectedProcess];
    if (info == nil) {
        return;
    }
    /* Killing a process outright loses whatever it had not saved, so it is
     * worth one question. */
    NSInteger answer = NSRunAlertPanel(
        @"Force Quit Process",
        @"%@ (%d) will be killed immediately. Anything it has not saved is "
         "lost, and programs it belongs to may misbehave afterwards.",
        @"Cancel", @"Force Quit", nil, [info displayName], info.pid);
    if (answer == NSAlertDefaultReturn) {
        return;
    }
    [self actOnSelectionWithSignal:SIGKILL];
}

- (IBAction)suspendProcess:(id)sender
{
    [self actOnSelectionWithSignal:SIGSTOP];
}

- (IBAction)resumeProcess:(id)sender
{
    [self actOnSelectionWithSignal:SIGCONT];
}

- (IBAction)showProcessInfo:(id)sender
{
    if ([self selectedProcess] == nil) {
        return;
    }
    [self ensureInfoDrawer];
    [self updateInfoDrawer];
    [_infoDrawer open];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    if (action == @selector(showProcessInfo:) ||
        action == @selector(quitProcess:) ||
        action == @selector(forceQuitProcess:) ||
        action == @selector(suspendProcess:) ||
        action == @selector(resumeProcess:)) {
        return ([self selectedProcess] != nil);
    }
    return YES;
}

/* --- sorting ------------------------------------------------------------ */

- (void)sortProcesses
{
    if ([_sortDescriptors count] > 0) {
        NSArray *descriptors = _sortDescriptors;
        /* Sorting by severity alone leaves the order within a severity to
         * chance; the busiest process is the interesting one there. */
        if ([[[_sortDescriptors objectAtIndex:0] key] isEqualToString:@"healthLevel"]) {
            NSSortDescriptor *byCPU = [[NSSortDescriptor alloc] initWithKey:@"cpu"
                                                                  ascending:NO];
            descriptors = [_sortDescriptors arrayByAddingObject:byCPU];
        }
        [_processesLock lock];
        [_processes sortUsingDescriptors:descriptors];
        [_processesLock unlock];
    }
    [self updateVisibleProcesses];
}

// NSTableViewDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[_visibleProcesses count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)[_visibleProcesses count]) {
        return @"";
    }
    ProcessInfo *info = [_visibleProcesses objectAtIndex:row];
    NSString *identifier = [tableColumn identifier];

    if ([identifier isEqualToString:@"health"]) {
        return levelImage([info healthLevel]);
    }
    if ([identifier isEqualToString:@"pid"]) {
        return [NSString stringWithFormat:@"%d", info.pid];
    }
    if ([identifier isEqualToString:@"user"]) {
        return info.user ? info.user : @"";
    }
    if ([identifier isEqualToString:@"cpu"]) {
        return [NSString stringWithFormat:@"%.1f", info.cpu];
    }
    if ([identifier isEqualToString:@"memory"]) {
        return ProcessFormatMemoryKB(info.residentMemory);
    }
    if ([identifier isEqualToString:@"status"]) {
        return [info statusText];
    }
    if ([identifier isEqualToString:@"command"]) {
        return info.command ? info.command : @"";
    }
    return @"";
}

// NSTableViewDelegate
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    ProcessInfo *info = [self selectedProcess];
    [self setActionButtonsEnabled:(info != nil)];
    /* GNUstep revalidates only the submenus that are open on screen, so the
     * Process menu would stay greyed out until it is opened twice - and a
     * menu item the global menu bar believes to be disabled is dropped. */
    for (NSMenuItem *item in [[NSApp mainMenu] itemArray]) {
        [[item submenu] update];
    }
    if (info != nil && _infoDrawer != nil &&
        [_infoDrawer state] != NSDrawerClosedState) {
        [self updateInfoDrawer];
    }
    [_processesTableView setNeedsDisplay:YES];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if ([cell respondsToSelector:@selector(setDrawsBackground:)]) {
        [cell setDrawsBackground:NO];
    }
    if (![cell respondsToSelector:@selector(setTextColor:)]) {
        return;
    }
    if ([tableView isRowSelected:row]) {
        [cell setTextColor:[NSColor selectedTextColor]];
        return;
    }
    NSInteger level = 0;
    if (row >= 0 && row < (NSInteger)[_visibleProcesses count]) {
        level = [[_visibleProcesses objectAtIndex:row] healthLevel];
    }
    [cell setTextColor:levelTextColor(level)];
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn
{
    // Not needed, handled by sortDescriptorsDidChange
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors
{
    _sortDescriptors = [tableView sortDescriptors];
    [self sortProcesses];
}

- (void)tableViewDoubleClick:(id)sender
{
    [self showProcessInfo:sender];
}

/* --- the inspector ------------------------------------------------------ */

- (NSString *)nameForPid:(int)pid
{
    for (ProcessInfo *info in _processes) {
        if (info.pid == pid) {
            return [info displayName];
        }
    }
    return nil;
}

/* The drawer's labels: plain text on the drawer background. */
- (NSTextField *)drawerLabelWithFont:(NSFont *)font
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setEditable:NO];
    [label setSelectable:YES];
    [label setBordered:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setFont:font];
    return label;
}

- (NSButton *)actionButtonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    [button setEnabled:NO];
    return button;
}

- (void)setActionButtonsEnabled:(BOOL)enabled
{
    [_quitButton setEnabled:enabled];
    [_forceQuitButton setEnabled:enabled];
    [_suspendButton setEnabled:enabled];
    [_resumeButton setEnabled:enabled];
}

- (void)ensureInfoDrawer
{
    if (_infoDrawer != nil) {
        return;
    }

    _infoDrawer = [[NSDrawer alloc]
        initWithContentSize:NSMakeSize(kDrawerWidth, kDrawerHeight)
              preferredEdge:NSMaxXEdge];
    [_infoDrawer setParentWindow:_mainWindow];
    [_infoDrawer setDelegate:self];
    [_infoDrawer setMinContentSize:NSMakeSize(kDrawerWidth, 260.0)];

    ProcessesDrawerView *content = [[ProcessesDrawerView alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, kDrawerWidth, kDrawerHeight)];
    [content setLayoutOwner:self];
    _drawerContentView = content;
    [_infoDrawer setContentView:content];

    _drawerTitleLabel = [self drawerLabelWithFont:
        [NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
    [content addSubview:_drawerTitleLabel];

    _drawerStatusLabel = [self drawerLabelWithFont:
        [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [content addSubview:_drawerStatusLabel];

    _memorySparkline = [[SparklineView alloc] initWithFrame:NSZeroRect];
    [_memorySparkline setCaption:@"Memory"];
    [content addSubview:_memorySparkline];

    _cpuSparkline = [[SparklineView alloc] initWithFrame:NSZeroRect];
    [_cpuSparkline setCaption:@"CPU"];
    /* One core fully busy is the yardstick, so the curve of a process using
     * half a core looks like half a core. */
    [_cpuSparkline setMaximum:100.0];
    [_cpuSparkline setLineColor:[NSColor colorWithCalibratedRed:0.75
                                                          green:0.40
                                                           blue:0.10
                                                          alpha:1.0]];
    [content addSubview:_cpuSparkline];

    _explanationScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [_explanationScrollView setHasVerticalScroller:YES];
    [_explanationScrollView setBorderType:NSBezelBorder];
    _explanationTextView = [[NSTextView alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, kDrawerWidth, kDrawerHeight)];
    [_explanationTextView setEditable:NO];
    [_explanationTextView setSelectable:YES];
    [_explanationTextView setFont:[NSFont systemFontOfSize:
                                      [NSFont smallSystemFontSize]]];
    [_explanationTextView setHorizontallyResizable:NO];
    [_explanationTextView setVerticallyResizable:YES];
    [[_explanationTextView textContainer] setWidthTracksTextView:YES];
    [_explanationTextView setAutoresizingMask:NSViewWidthSizable];
    [_explanationScrollView setDocumentView:_explanationTextView];
    [content addSubview:_explanationScrollView];

    _quitButton = [self actionButtonWithTitle:@"Quit"
                                       action:@selector(quitProcess:)];
    [content addSubview:_quitButton];
    _forceQuitButton = [self actionButtonWithTitle:@"Force Quit"
                                            action:@selector(forceQuitProcess:)];
    [content addSubview:_forceQuitButton];
    _suspendButton = [self actionButtonWithTitle:@"Suspend"
                                          action:@selector(suspendProcess:)];
    [content addSubview:_suspendButton];
    _resumeButton = [self actionButtonWithTitle:@"Resume"
                                         action:@selector(resumeProcess:)];
    [content addSubview:_resumeButton];

    [self setActionButtonsEnabled:([self selectedProcess] != nil)];
    [self layoutDrawerContent];
}

/* Laid out in code rather than by autoresizing: GNUstep sizes the drawer's
 * container box after the PARENT window, so the content view is far larger
 * than the strip of it the drawer shows.  Everything is therefore placed
 * inside that visible strip, and the oversized view around it stays empty. */
- (NSRect)visibleDrawerRect
{
    NSRect bounds = [_drawerContentView bounds];
    NSWindow *window = [_drawerContentView window];
    NSView *windowContent = [window contentView];
    if (window == nil || windowContent == nil || windowContent == _drawerContentView) {
        return bounds;
    }
    NSRect visible = [_drawerContentView convertRect:[windowContent bounds]
                                            fromView:windowContent];
    visible = NSIntersectionRect(visible, bounds);
    if (NSWidth(visible) < 80.0 || NSHeight(visible) < 80.0) {
        return bounds;
    }
    return visible;
}

- (void)layoutDrawerContent
{
    if (_drawerTitleLabel == nil || _drawerContentView == nil) {
        return;
    }

    const CGFloat margin = 12.0;
    const CGFloat buttonHeight = 24.0;
    const CGFloat gap = 6.0;

    NSRect area = NSInsetRect([self visibleDrawerRect], margin, margin);
    CGFloat left = NSMinX(area);
    CGFloat width = NSWidth(area);
    if (width < 80.0) {
        width = 80.0;
    }
    CGFloat buttonWidth = (width - 8.0) / 2.0;

    CGFloat y = NSMaxY(area) - 18.0;
    [_drawerTitleLabel setFrame:NSMakeRect(left, y, width, 18.0)];
    y -= 4.0 + 16.0;
    [_drawerStatusLabel setFrame:NSMakeRect(left, y, width, 16.0)];

    /* The two curves keep their height; the explanation takes what is left. */
    y -= 10.0 + kSparklineHeight;
    [_memorySparkline setFrame:NSMakeRect(left, y, width, kSparklineHeight)];
    y -= gap + kSparklineHeight;
    [_cpuSparkline setFrame:NSMakeRect(left, y, width, kSparklineHeight)];

    CGFloat secondRow = NSMinY(area);
    CGFloat firstRow = secondRow + buttonHeight + gap;
    [_suspendButton setFrame:NSMakeRect(left, secondRow, buttonWidth, buttonHeight)];
    [_resumeButton setFrame:NSMakeRect(left + buttonWidth + 8.0, secondRow,
                                       buttonWidth, buttonHeight)];
    [_quitButton setFrame:NSMakeRect(left, firstRow, buttonWidth, buttonHeight)];
    [_forceQuitButton setFrame:NSMakeRect(left + buttonWidth + 8.0, firstRow,
                                          buttonWidth, buttonHeight)];

    CGFloat textBottom = firstRow + buttonHeight + 10.0;
    CGFloat textHeight = y - gap - textBottom;
    if (textHeight < 40.0) {
        textHeight = 40.0;
    }
    [_explanationScrollView setFrame:NSMakeRect(left, textBottom, width,
                                                textHeight)];
}

- (void)updateInfoDrawer
{
    ProcessInfo *info = [self selectedProcess];
    if (info == nil || _infoDrawer == nil) {
        return;
    }

    /* The drawer takes its size from the window only when it opens, and
     * nothing tells the content view about it. */
    [self layoutDrawerContent];

    [_drawerTitleLabel setStringValue:[NSString stringWithFormat:@"%@ (%d)",
                                                [info displayName], info.pid]];

    ProcessHealth *health = info.health;
    NSString *summary = [health summary];
    [_drawerStatusLabel setStringValue:(summary != nil ? summary
                                                       : @"Nothing looks wrong")];
    [_drawerStatusLabel setTextColor:levelTextColor([info healthLevel])];

    NSTimeInterval watched = [_history observedDurationForPid:info.pid];
    NSString *span = ProcessFormatDuration(watched);
    long watchedPeakKB = [_history peakResidentKBForPid:info.pid];

    /* Both curves cover the watched window, so they say which window that
     * is; the figure the kernel remembers is in the facts below. */
    [_memorySparkline setCaption:
        [NSString stringWithFormat:@"Memory, last %@", span]];
    [_memorySparkline setValues:[_history residentMBSamplesForPid:info.pid]];
    /* Headroom above the highest sample, so a flat line does not sit on the
     * ceiling and read as a limit that has been reached. */
    [_memorySparkline setMaximum:((double)watchedPeakKB / 1024.0) * 1.2];
    [_memorySparkline setValueText:
        [NSString stringWithFormat:@"%@ now, up to %@",
                  ProcessFormatMemoryKB(info.residentMemory),
                  ProcessFormatMemoryKB(watchedPeakKB)]];

    [_cpuSparkline setCaption:
        [NSString stringWithFormat:@"CPU, last %@", span]];
    [_cpuSparkline setValues:[_history cpuSamplesForPid:info.pid]];
    [_cpuSparkline setValueText:[NSString stringWithFormat:@"%.1f%% now", info.cpu]];

    NSMutableString *text = [NSMutableString string];
    if ([health explanation] != nil) {
        [text appendString:[health explanation]];
        [text appendString:@"\n\n"];
    }
    NSString *parentName = [self nameForPid:info.ppid];
    [text appendFormat:@"Owner: %@\n", (info.user ? info.user : @"unknown")];
    [text appendFormat:@"Started by: %d%@\n", info.ppid,
                       (parentName != nil
                            ? [NSString stringWithFormat:@" (%@)", parentName] : @"")];
    [text appendFormat:@"State: %@\n", [info stateDescription]];
    if (info.threads > 0) {
        [text appendFormat:@"Threads: %d\n", info.threads];
    }
    [text appendFormat:@"Memory: %@ (%.1f%% of the machine)\n",
                       ProcessFormatMemoryKB(info.residentMemory), info.memory];
    /* The kernel's high-water mark reaches back to the start of the process,
     * far beyond anything this application can have watched. */
    long everKB = [info peakResidentMemory];
    if (everKB > 0) {
        [text appendFormat:@"Most it ever held: %@\n",
                           ProcessFormatMemoryKB(everKB)];
    }
    if (info.virtualMemory > 0) {
        [text appendFormat:@"Address space: %@\n",
                           ProcessFormatMemoryKB(info.virtualMemory)];
    }
    double growth = [_history memoryGrowthMBPerMinuteForPid:info.pid];
    if (growth > 0.05 || growth < -0.05) {
        [text appendFormat:@"Memory trend: %+.2f MB per minute\n", growth];
    }
    [text appendFormat:@"Watched for: %@\n", span];
    [text appendFormat:@"Command: %@\n", (info.command ? info.command : @"")];

    [_explanationTextView setString:text];
}

/* --- application and window -------------------------------------------- */

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    PC_INFO(@"applicationDidFinishLaunching start");
    [self createUI];
    [self startMonitoring];
    [_mainWindow makeKeyAndOrderFront:self];

    /* The first round has no previous reading to compare against, so a second
     * one follows right away to fill in the CPU figures. */
    [self refreshProcesses];
    [self performSelector:@selector(refreshProcesses) withObject:nil afterDelay:1.0];
}

- (NSMenu *)buildProcessMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Process"];
    NSMenuItem *item;

    item = (NSMenuItem *)[menu addItemWithTitle:@"Get Info"
                                         action:@selector(showProcessInfo:)
                                  keyEquivalent:@"i"];
    [item setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    item = (NSMenuItem *)[menu addItemWithTitle:@"Quit Process"
                                         action:@selector(quitProcess:)
                                  keyEquivalent:@""];
    [item setTarget:self];
    item = (NSMenuItem *)[menu addItemWithTitle:@"Force Quit Process"
                                         action:@selector(forceQuitProcess:)
                                  keyEquivalent:@""];
    [item setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    item = (NSMenuItem *)[menu addItemWithTitle:@"Suspend"
                                         action:@selector(suspendProcess:)
                                  keyEquivalent:@""];
    [item setTarget:self];
    item = (NSMenuItem *)[menu addItemWithTitle:@"Resume"
                                         action:@selector(resumeProcess:)
                                  keyEquivalent:@""];
    [item setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    item = (NSMenuItem *)[menu addItemWithTitle:@"Refresh Now"
                                         action:@selector(refreshNow:)
                                  keyEquivalent:@"r"];
    [item setTarget:self];

    return menu;
}

- (void)setupMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Processes"];
    NSMenuItem *appMenuItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"Processes" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Processes"];

    [appMenu addItemWithTitle:@"About Processes" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Processes" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Processes" action:@selector(terminate:) keyEquivalent:@"q"];

    [mainMenu setSubmenu:appMenu forItem:appMenuItem];

    // Process Menu: what can be done with the selected process
    NSMenuItem *processMenuItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"Process" action:NULL keyEquivalent:@""];
    [mainMenu setSubmenu:[self buildProcessMenu] forItem:processMenuItem];

    // Window Menu
    NSMenuItem *windowMenuItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [mainMenu setSubmenu:windowMenu forItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];

    [NSApp setMainMenu:mainMenu];
}

- (NSTableColumn *)addColumnWithIdentifier:(NSString *)identifier
                                     title:(NSString *)title
                                     width:(CGFloat)width
                                   sortKey:(NSString *)sortKey
                                 ascending:(BOOL)ascending
                                 alignment:(NSTextAlignment)alignment
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    if (sortKey != nil) {
        [column setSortDescriptorPrototype:
            [[NSSortDescriptor alloc] initWithKey:sortKey ascending:ascending]];
    }
    [[column dataCell] setAlignment:alignment];
    [[column headerCell] setAlignment:alignment];
    [_processesTableView addTableColumn:column];
    return column;
}

- (void)createUI
{
    const CGFloat topStrip = 26.0;
    const CGFloat bottomStrip = 22.0;

    // Create main window
    _mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 840, 600)
                                                styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    /* Owned by ARC through this reference; if it were also released on
     * close, -close would release it a second time. */
    [_mainWindow setReleasedWhenClosed:NO];
    [_mainWindow setTitle:@"Processes"];
    [_mainWindow setDelegate:self];
    [_mainWindow setMinSize:NSMakeSize(560.0, 320.0)];

    [self setupMenu];

    NSRect bounds = [[_mainWindow contentView] bounds];

    // Only the processes that look wrong, for when something is going on
    _problemsOnlyCheckbox = [[NSButton alloc]
        initWithFrame:NSMakeRect(8.0, NSHeight(bounds) - topStrip + 2.0, 200.0, 20.0)];
    [_problemsOnlyCheckbox setButtonType:NSSwitchButton];
    [_problemsOnlyCheckbox setTitle:@"Only what looks wrong"];
    [_problemsOnlyCheckbox setTarget:self];
    [_problemsOnlyCheckbox setAction:@selector(toggleProblemsOnly:)];
    [_problemsOnlyCheckbox setAutoresizingMask:NSViewMinYMargin];
    [[_mainWindow contentView] addSubview:_problemsOnlyCheckbox];

    // Search field at the top right
    _searchField = [[NSSearchField alloc]
        initWithFrame:NSMakeRect(NSWidth(bounds) - 220.0,
                                 NSHeight(bounds) - topStrip + 2.0, 200.0, 22.0)];
    [_searchField setPlaceholderString:@"Filter processes..."];
    [_searchField setDelegate:self];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchFieldAction:)];
    [[_searchField cell] setRecentsAutosaveName:@"ProcessesFilter"];
    [_searchField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [[_mainWindow contentView] addSubview:_searchField];

    // What the whole list adds up to
    _summaryLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(8.0, 3.0, NSWidth(bounds) - 16.0, 16.0)];
    [_summaryLabel setEditable:NO];
    [_summaryLabel setSelectable:NO];
    [_summaryLabel setBordered:NO];
    [_summaryLabel setBezeled:NO];
    [_summaryLabel setDrawsBackground:NO];
    [_summaryLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_summaryLabel setStringValue:@"Reading the process list..."];
    [_summaryLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [[_mainWindow contentView] addSubview:_summaryLabel];

    // Create scroll view for table
    NSScrollView *scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0.0, bottomStrip, NSWidth(bounds),
                                 NSHeight(bounds) - topStrip - bottomStrip)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:YES];
    [scrollView setAutohidesScrollers:YES];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Create table view
    _processesTableView = [[ProcessTableView alloc] initWithFrame:[scrollView bounds]];
    [_processesTableView setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_processesTableView setRowHeight:[_processesTableView rowHeight] - 2.0];
    [_processesTableView setDataSource:self];
    [_processesTableView setDelegate:self];
    [_processesTableView setAllowsMultipleSelection:NO];
    [_processesTableView setIntercellSpacing:NSMakeSize(0, 0)];
    [_processesTableView setGridStyleMask:NSTableViewGridNone];
    [_processesTableView setTarget:self];
    [_processesTableView setDoubleAction:@selector(tableViewDoubleClick:)];
    [_processesTableView setMenu:[self buildProcessMenu]];

    /* A dot, so that a process in trouble is visible before anything is
     * read. */
    NSTableColumn *healthColumn = [self addColumnWithIdentifier:@"health"
                                                          title:@""
                                                          width:18.0
                                                        sortKey:@"healthLevel"
                                                      ascending:NO
                                                      alignment:NSCenterTextAlignment];
    [healthColumn setDataCell:[[NSImageCell alloc] init]];
    [healthColumn setMinWidth:18.0];
    [healthColumn setMaxWidth:18.0];

    [self addColumnWithIdentifier:@"pid" title:@"PID" width:56.0
                          sortKey:@"pid" ascending:YES
                        alignment:NSRightTextAlignment];
    [self addColumnWithIdentifier:@"user" title:@"User" width:80.0
                          sortKey:@"user" ascending:YES
                        alignment:NSLeftTextAlignment];
    [self addColumnWithIdentifier:@"cpu" title:@"CPU %" width:56.0
                          sortKey:@"cpu" ascending:NO
                        alignment:NSRightTextAlignment];
    [self addColumnWithIdentifier:@"memory" title:@"Memory" width:80.0
                          sortKey:@"residentMemory" ascending:NO
                        alignment:NSRightTextAlignment];
    [self addColumnWithIdentifier:@"status" title:@"Status" width:180.0
                          sortKey:@"healthLevel" ascending:NO
                        alignment:NSLeftTextAlignment];
    [self addColumnWithIdentifier:@"command" title:@"Command" width:340.0
                          sortKey:@"command" ascending:YES
                        alignment:NSLeftTextAlignment];

    /* Default order: whatever looks wrong first, then the busiest, which is
     * the order the user came to look for. */
    _sortDescriptors = [NSArray arrayWithObject:
        [[NSSortDescriptor alloc] initWithKey:@"healthLevel" ascending:NO]];
    [_processesTableView setSortDescriptors:_sortDescriptors];

    [scrollView setDocumentView:_processesTableView];
    [[_mainWindow contentView] addSubview:scrollView];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end
