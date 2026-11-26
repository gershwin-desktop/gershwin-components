/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSCrashPlatform_h
#define GSCrashPlatform_h

#import <Foundation/Foundation.h>

/*
 * Platform abstraction layer (SPEC section 7). Each supported OS provides a
 * concrete subclass. The GNUstep-specific machinery stays common; only the
 * crash-collection backend differs per OS.
 */
@protocol GSCrashPlatform <NSObject>

/* Human-readable platform tag: "Linux", "FreeBSD", "OpenBSD", "NetBSD". */
- (NSString *)platformName;

/*
 * Determine whether core dumps are being produced at all (RLIMIT_CORE / kernel
 * configuration). Returns NO if the current core-size limit is zero or the
 * kernel is not configured to emit cores.
 */
- (BOOL)isCoreDumpingEnabled;

/*
 * The directory where a freshly generated core file will appear, given current
 * configuration. May be nil if unknown (e.g. piped to a collector).
 */
- (NSString *)coreDumpLocation;

/*
 * Detect any pre-existing crash collector we must coexist with (SPEC section 24):
 * returns one of "systemd-coredump", "abrt", "core_pattern-pipe", "kernel",
 * or "none".
 */
- (NSString *)existingCrashCollector;

/*
 * Save the current administrative core configuration so it can be restored
 * later (SPEC section 8). Idempotent.
 */
- (BOOL)saveCoreConfiguration:(NSError **)error;

/*
 * Restore the configuration previously saved via -saveCoreConfiguration:.
 */
- (BOOL)restoreCoreConfiguration:(NSError **)error;

/*
 * Configure the OS to emit core dumps into `directory` (SPEC section 7/31).
 * This may require privilege; if it cannot be done, set *error and return NO
 * WITHOUT mutating an administrator-controlled configuration. Never blindly
 * overwrite an existing core_pattern.
 */
- (BOOL)configureCoreDumpsToDirectory:(NSString *)directory error:(NSError **)error;

/*
 * Install whatever OS-level crash monitor is appropriate (e.g. register for
 * notifications, set up a watcher). The daemon still does directory watching;
 * this hook is for OS-native notification paths.
 */
- (BOOL)installCrashMonitor:(NSError **)error;

/*
 * Best-effort start of the crash service. For user services this may be a
 * no-op because the daemon IS the service. Returns YES if the service can run.
 */
- (BOOL)startCrashService:(NSError **)error;

@end

/*
 * Factory: returns the platform object for the running OS. Falls back to a
 * generic implementation that degrades gracefully when unknown.
 */
id<GSCrashPlatform> GSCrashPlatformForCurrentOS(void);

#endif /* GSCrashPlatform_h */
