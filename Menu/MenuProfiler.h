//
//  MenuProfiler.h
//  Menu - Lightweight CPU profiling instrumentation
//
//  Enabled at compile time with -DMENU_PROFILING=1.
//  When disabled, all macros compile to nothing (zero overhead).
//
//  Usage:
//      MENU_PROFILE_BEGIN(updateMenuBar);
//      ... work ...
//      MENU_PROFILE_END(updateMenuBar);
//
//  A summary is printed to stderr every MENU_PROFILE_INTERVAL seconds
//  and on demand via SIGUSR1.
//

#ifndef MENU_PROFILER_H
#define MENU_PROFILER_H

#if MENU_PROFILING

#include <time.h>
#include <stdint.h>

// ── Public API ──────────────────────────────────────────────────────

/// Register a named probe and return its index (idempotent per name).
int menuProbeRegister(const char *name);

/// Record a measurement for the given probe index.
void menuProbeRecord(int index, uint64_t nanos);

/// Print the current stats table to stderr and reset counters.
void menuProfileDump(void);

/// Install SIGUSR1 handler for on-demand dumps. Call once at startup.
void menuProfileInstallSignalHandler(void);

// ── Macros ──────────────────────────────────────────────────────────

#define MENU_PROFILE_BEGIN(label) \
    struct timespec _menu_ts_##label; \
    clock_gettime(CLOCK_MONOTONIC, &_menu_ts_##label)

#define MENU_PROFILE_END(label) do { \
    struct timespec _menu_te_##label; \
    clock_gettime(CLOCK_MONOTONIC, &_menu_te_##label); \
    uint64_t _menu_ns_##label = \
        (uint64_t)(_menu_te_##label.tv_sec - _menu_ts_##label.tv_sec) * 1000000000ULL \
        + (uint64_t)(_menu_te_##label.tv_nsec - _menu_ts_##label.tv_nsec); \
    static int _menu_idx_##label = -1; \
    if (_menu_idx_##label == -1) _menu_idx_##label = menuProbeRegister(#label); \
    menuProbeRecord(_menu_idx_##label, _menu_ns_##label); \
} while (0)

#else /* MENU_PROFILING disabled */

#define MENU_PROFILE_BEGIN(label)  ((void)0)
#define MENU_PROFILE_END(label)    ((void)0)

static inline void menuProfileInstallSignalHandler(void) {}
static inline void menuProfileDump(void) {}

#endif /* MENU_PROFILING */
#endif /* MENU_PROFILER_H */
