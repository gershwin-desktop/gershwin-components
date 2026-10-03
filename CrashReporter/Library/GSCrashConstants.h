/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSCrashConstants_h
#define GSCrashConstants_h

#import <Foundation/Foundation.h>

/*
 * Reverse-DNS namespace for Gershwin CrashReporter. We never use org.gershwin.
 */
#define GSCrashReverseDNS @"io.github.gershwin-desktop.CrashReporter"

/*
 * Distributed notification posted (via NSDistributedNotificationCenter) when a
 * crash has been analyzed and a report is ready for the logged-in user.
 * The userInfo carries GSCrashNotificationCrashDirKey -> crash directory path.
 */
#define GSCrashNotificationName (GSCrashReverseDNS @"/CrashDetected")
#define GSCrashNotificationCrashDirKey @"CrashDirectory"

/*
 * Crash directory layout (stable across releases).
 */
#define GSCrashReportJSON     @"report.json"
#define GSCrashReportTXT      @"report.txt"
#define GSCrashCoreFile       @"core"
#define GSCrashMapsFile       @"maps"
#define GSCrashModulesFile    @"modules"
#define GSCrashEnvFile        @"environment"
#define GSCrashRegistersFile  @"registers"
#define GSCrashBacktraceFile  @"backtrace.txt"
#define GSCrashMetadataFile   @"metadata.json"
#define GSCrashMarkerDir      @"markers"

/*
 * Keys used inside a crash marker file (written by libGSCrashReporter from a
 * signal/exception handler and read by gs-crashd).
 */
#define GSCrashMarkerAppKey        @"application"
#define GSCrashMarkerVersionKey    @"version"
#define GSCrashMarkerPIDKey        @"pid"
#define GSCrashMarkerUIDKey        @"uid"
#define GSCrashMarkerExecKey       @"executable"
#define GSCrashMarkerSignalKey     @"signal"
#define GSCrashMarkerExceptionKey  @"exception"
#define GSCrashMarkerReasonKey     @"reason"
#define GSCrashMarkerTimestampKey  @"timestamp"
#define GSCrashMarkerBuildIDKey    @"build_id"

/*
 * Returns the per-user crash base directory:
 *   $XDG_STATE_HOME/gnustep/CrashReporter
 * falling back to
 *   ~/.local/state/gnustep/CrashReporter
 * The directory is created (0700) if necessary.
 */
NSString *GSCrashBaseDirectory(void);

/*
 * Returns a freshly created, unique crash directory for the given application:
 *   <base>/<AppName>/<YYYY-MM-DD-HH-MM-SS-<pid>>/
 * The leaf directory is created with 0700 permissions. AppName is sanitized.
 */
NSString *GSCrashNewCrashDirectory(NSString *applicationName, pid_t pid);

/*
 * Sanitize a string so it is safe to use as a filesystem component.
 */
NSString *GSCrashSanitizeComponent(NSString *in);

/*
 * Human-readable GNUstep Base / GUI versions, or @"unknown".
 */
NSString *GSCrashGNUstepBaseVersion(void);
NSString *GSCrashGNUstepGUIVersion(void);

/*
 * Current OS name/version/architecture via uname.
 */
NSString *GSCrashOSName(void);
NSString *GSCrashOSVersion(void);
NSString *GSCrashArchitecture(void);

#endif /* GSCrashConstants_h */
