/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashReporter.h"
#import "GSCrashConstants.h"
#import "gscrash_marker.h"
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import <objc/runtime.h>

/* Cached, signal-handler-safe state (set once during +install, read only after). */
static char g_markers_dir[1024];
static char g_app_name[256];
static char g_exec_path[1024];
static volatile sig_atomic_t g_installed = 0;

static struct sigaction g_prev_handlers[NSIG];
static int g_tracked_signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
static const char *g_signal_names[] = { "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGABRT", "SIGTRAP" };

static const char *signal_to_name(int sig)
{
    for (size_t i = 0; i < sizeof(g_tracked_signals)/sizeof(g_tracked_signals[0]); i++)
        if (g_tracked_signals[i] == sig)
            return g_signal_names[i];
    return "SIGUNKNOWN";
}

static void gscrash_signal_handler(int sig, siginfo_t *info, void *ucontext)
{
    (void)info;
    (void)ucontext;
    /*
     * Minimal handler (SPEC section 11): write a marker, then restore the
     * default disposition and re-raise so the kernel generates the core and
     * terminates the process normally. No memory allocation, no ObjC, no locks.
     */
    gscrash_write_signal_marker(g_markers_dir,
                                g_app_name,
                                g_exec_path,
                                getpid(),
                                getuid(),
                                signal_to_name(sig),
                                NULL, NULL, NULL);

    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigaction(sig, &dfl, NULL);
    raise(sig);
}

static void gscrash_uncaught_exception(NSException *exception)
{
    /*
     * Uncaught Objective-C exception (SPEC section 12). Safe to use Foundation
     * here; we write a marker and let termination proceed. The actual core dump
     * remains authoritative for native state.
     */
    NSString *markers = [NSString stringWithUTF8String:g_markers_dir];
    NSString *app = [NSString stringWithUTF8String:g_app_name];
    NSString *exec = [NSString stringWithUTF8String:g_exec_path];
    NSString *name = [exception name];
    NSString *reason = [exception reason];
    gscrash_write_signal_marker([markers UTF8String],
                                [app UTF8String],
                                [exec UTF8String],
                                getpid(),
                                getuid(),
                                NULL,
                                [name UTF8String],
                                [reason UTF8String],
                                NULL);
}

@implementation GSCrashReporter

+ (void)setApplicationName:(NSString *)name
{
    if (name)
    {
        NSString *s = GSCrashSanitizeComponent(name);
        strncpy(g_app_name, [s UTF8String], sizeof(g_app_name) - 1);
    }
}

+ (void)setApplicationVersion:(NSString *)version
{
    (void)version; /* reserved; stored in marker via future wiring */
}

+ (BOOL)writeMarkerWithSignal:(NSString *)signal
                    exception:(NSString *)exceptionName
                       reason:(NSString *)reason
{
    if (g_markers_dir[0] == '\0')
        return NO;
    return gscrash_write_signal_marker(g_markers_dir,
                                       g_app_name,
                                       g_exec_path,
                                       getpid(),
                                       getuid(),
                                       [signal UTF8String],
                                       [exceptionName UTF8String],
                                       [reason UTF8String],
                                       NULL) == 0;
}

+ (void)install
{
    if (g_installed)
        return;
    g_installed = 1;

    /* Resolve and create the per-user markers directory (0700). */
    NSString *base = GSCrashBaseDirectory();
    NSString *markers = [base stringByAppendingPathComponent:GSCrashMarkerDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:markers
     withIntermediateDirectories:YES
                      attributes:@{ NSFilePosixPermissions : @(0700) }
                           error:nil];
    strncpy(g_markers_dir, [markers UTF8String], sizeof(g_markers_dir) - 1);

    /* Application identity. */
    NSString *app = [[NSProcessInfo processInfo] processName];
    NSString *exec = nil;
#if defined(__linux__)
    char buf[1024];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = '\0'; exec = [NSString stringWithUTF8String:buf]; }
#endif
    if (exec == nil)
    {
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        if ([args count])
            exec = [[NSBundle mainBundle] executablePath] ?: args[0];
    }
    if (app == nil) app = @"Unknown";
    if (exec == nil) exec = @"";
    NSString *san = GSCrashSanitizeComponent(app);
    strncpy(g_app_name, [san UTF8String], sizeof(g_app_name) - 1);
    strncpy(g_exec_path, [exec UTF8String], sizeof(g_exec_path) - 1);

    /* Install minimal signal handlers (SPEC 11). */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = gscrash_signal_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(g_tracked_signals)/sizeof(g_tracked_signals[0]); i++)
    {
        int sig = g_tracked_signals[i];
        sigaction(sig, &sa, &g_prev_handlers[sig]);
    }

    /* Install uncaught exception handler (SPEC 12). */
    NSSetUncaughtExceptionHandler(&gscrash_uncaught_exception);
}

@end
