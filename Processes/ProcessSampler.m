/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessSampler.h"
#import "ProcessInfo.h"

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
#import <errno.h>
#import <string.h>

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

#define PC_INFO(fmt, ...) NSDebugLLog(@"gwcomp", (@"[Processes] " fmt), ##__VA_ARGS__)

/* Reading every process is not free, so a scan that takes longer than this is
 * cut short rather than pegging a core. */
static const double kMaxScanSeconds = 3.0;

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


@implementation ProcessSampler

+ (NSArray *)scanProcessesTruncated:(BOOL *)truncated
{
    NSMutableArray *processes = [[NSMutableArray alloc] init];
    BOOL cutShort = NO;

    if (!scanProcFilesystem(processes, &cutShort)) {
        scanSysctl(processes);
    } else if ([processes count] == 0) {
        PC_INFO(@"/proc yielded no processes, asking sysctl");
        scanSysctl(processes);
    }
    if ([processes count] == 0) {
        PC_INFO(@"falling back to parsing ps aux");
        scanPsAux(processes);
    }
    if (truncated != NULL) {
        *truncated = cutShort;
    }
    return processes;
}

+ (long)totalMemoryKB
{
    return getTotalSystemMemoryKB();
}

+ (NSString *)userNameForUid:(uid_t)uid
{
    return userNameForUid(uid, [NSMutableDictionary dictionary]);
}

@end
