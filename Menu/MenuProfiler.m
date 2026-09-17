//
//  MenuProfiler.m
//  Menu - Lightweight CPU profiling instrumentation
//
//  Collects per-probe call counts, total/min/max times since launch.
//  Dumps a sorted summary to stderr every MENU_PROFILE_INTERVAL seconds.
//

#if MENU_PROFILING

#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include "MenuProfiler.h"

// ── Configuration ───────────────────────────────────────────────────

#ifndef MENU_PROFILE_INTERVAL
#define MENU_PROFILE_INTERVAL 10.0   /* seconds between automatic dumps */
#endif

#define MENU_MAX_PROBES 64

// ── Probe storage ───────────────────────────────────────────────────

typedef struct {
    const char *name;
    uint64_t    callCount;
    uint64_t    totalNanos;
    uint64_t    minNanos;
    uint64_t    maxNanos;
} MenuProbeStats;

static MenuProbeStats sProbes[MENU_MAX_PROBES];
static int           sProbeCount = 0;
static struct timespec sLastDump;
static struct timespec sLaunchTime;
static int           sInitialized = 0;
static volatile sig_atomic_t sDumpRequested = 0;

// ── Internal helpers ────────────────────────────────────────────────

static void ensureInitialized(void) {
    if (sInitialized) return;
    clock_gettime(CLOCK_MONOTONIC, &sLastDump);
    sLaunchTime = sLastDump;
    sInitialized = 1;
}

static uint64_t elapsedSinceDump(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)(now.tv_sec - sLastDump.tv_sec) * 1000000000ULL
         + (uint64_t)(now.tv_nsec - sLastDump.tv_nsec);
}

static int compareByTotal(const void *a, const void *b) {
    const MenuProbeStats *pa = (const MenuProbeStats *)a;
    const MenuProbeStats *pb = (const MenuProbeStats *)b;
    if (pb->totalNanos > pa->totalNanos) return 1;
    if (pb->totalNanos < pa->totalNanos) return -1;
    return 0;
}

// ── Public API ──────────────────────────────────────────────────────

int menuProbeRegister(const char *name) {
    ensureInitialized();
    // Linear scan is fine - only called once per probe site (static local caches index).
    for (int i = 0; i < sProbeCount; i++) {
        if (sProbes[i].name == name) return i;   // pointer comparison - same literal
    }
    if (sProbeCount >= MENU_MAX_PROBES) {
        fprintf(stderr, "[Profile] WARNING: probe limit (%d) reached, ignoring '%s'\n",
                MENU_MAX_PROBES, name);
        return 0;
    }
    int idx = sProbeCount++;
    sProbes[idx].name = name;
    sProbes[idx].callCount = 0;
    sProbes[idx].totalNanos = 0;
    sProbes[idx].minNanos = UINT64_MAX;
    sProbes[idx].maxNanos = 0;
    return idx;
}

void menuProbeRecord(int index, uint64_t nanos) {
    MenuProbeStats *p = &sProbes[index];
    p->callCount++;
    p->totalNanos += nanos;
    if (nanos < p->minNanos) p->minNanos = nanos;
    if (nanos > p->maxNanos) p->maxNanos = nanos;

    // Drain any pending signal-triggered dump request (safe: called on runloop thread)
    if (sDumpRequested) {
        sDumpRequested = 0;
        menuProfileDump();
        return;
    }

    // Auto-dump every MENU_PROFILE_INTERVAL seconds
    uint64_t intervalNs = (uint64_t)(MENU_PROFILE_INTERVAL * 1e9);
    if (elapsedSinceDump() >= intervalNs) {
        menuProfileDump();
    }
}

void menuProfileDump(void) {
    if (sProbeCount == 0) return;

    // Compute wall-clock interval and process uptime
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double interval = (double)(now.tv_sec - sLastDump.tv_sec)
                    + (double)(now.tv_nsec - sLastDump.tv_nsec) / 1e9;
    double uptime = (double)(now.tv_sec - sLaunchTime.tv_sec)
                  + (double)(now.tv_nsec - sLaunchTime.tv_nsec) / 1e9;
    sLastDump = now;

    // Sort a copy by total time descending
    MenuProbeStats sorted[MENU_MAX_PROBES];
    memcpy(sorted, sProbes, sizeof(MenuProbeStats) * sProbeCount);
    qsort(sorted, sProbeCount, sizeof(MenuProbeStats), compareByTotal);

    fprintf(stderr,
            "\n═══ Menu Profile (since launch %.1fs, last dump %.1fs ago) ═══════════════\n"
            "%-28s %8s %10s %10s %10s %10s\n",
            uptime, interval,
            "Probe", "Calls", "Total ms", "Avg µs", "Min µs", "Max µs");

    for (int i = 0; i < sProbeCount; i++) {
        MenuProbeStats *p = &sorted[i];
        if (p->callCount == 0) continue;

        double totalMs = (double)p->totalNanos / 1e6;
        double avgUs   = (double)p->totalNanos / (double)p->callCount / 1e3;
        double minUs   = (double)p->minNanos / 1e3;
        double maxUs   = (double)p->maxNanos / 1e3;

        fprintf(stderr, "%-28s %8llu %10.1f %10.1f %10.1f %10.1f\n",
                p->name,
                (unsigned long long)p->callCount,
                totalMs, avgUs, minUs, maxUs);
    }
    fprintf(stderr,
            "════════════════════════════════════════════════════════════════════════\n\n");
}

// ── Signal handler ──────────────────────────────────────────────────

static void menuProfileSignalHandler(int sig) {
    (void)sig;
    sDumpRequested = 1;         /* async-signal-safe: just set a flag */
}

void menuProfileInstallSignalHandler(void) {
    ensureInitialized();
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = menuProfileSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGUSR1, &sa, NULL);
    fprintf(stderr, "[Profile] Instrumentation active - dump with: kill -USR1 %d\n", getpid());
}

#endif /* MENU_PROFILING */
