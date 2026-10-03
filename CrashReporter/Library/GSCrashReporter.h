/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSCrashReporter_h
#define GSCrashReporter_h

#import <Foundation/Foundation.h>

/*
 * libGSCrashReporter - the small, optional library applications may link to
 * make crash information available to the external crash service (SPEC 10/11/12).
 *
 * It does NOT perform analysis. Its only job is to install lightweight handlers
 * and write a minimal crash marker so gs-crashd can correlate a core with the
 * right application.
 */
@interface GSCrashReporter : NSObject

/*
 * Install crash integration for the calling application. Safe to call once at
 * startup. Records application metadata and installs:
 *   - NSSetUncaughtExceptionHandler (SPEC 12)
 *   - minimal signal handlers for SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT/SIGTRAP
 *     (SPEC 11)
 *
 * The handlers are async-signal-safe minimal: they write a marker file and let
 * the kernel generate the core / terminate the process normally.
 */
+ (void)install;

/*
 * Override the application name/version reported in the marker (defaults to the
 * process name and the CFBundle/Info.plist version when available).
 */
+ (void)setApplicationName:(NSString *)name;
+ (void)setApplicationVersion:(NSString *)version;

/*
 * Write a crash marker immediately (used by the signal/exception handlers and
 * for application-initiated "I am about to crash" notices). Returns YES if a
 * marker file was written.
 */
+ (BOOL)writeMarkerWithSignal:(NSString *)signal
                    exception:(NSString *)exceptionName
                       reason:(NSString *)reason;

@end

#endif /* GSCrashReporter_h */
