/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSCrashReport_h
#define GSCrashReport_h

#import <Foundation/Foundation.h>

/*
 * GSCrashReport is the canonical, machine-readable crash model. It round-trips
 * to report.json (see SPEC section 18) and renders to report.txt.
 *
 * All modules (daemon, analyzer, ctl, app) link libGSCrashReporter and use this
 * single source of truth. Raw artifacts (core, maps, modules, registers,
 * backtrace.txt) live as sidecar files in the crash directory; this object
 * records their relative names and provenance.
 */
@interface GSCrashReport : NSObject <NSCopying>

/* Application (SPEC section 6, required) */
@property (nonatomic, copy) NSString *applicationName;
@property (nonatomic, copy) NSString *applicationVersion;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, assign) uid_t uid;

/* System (SPEC section 6, required) */
@property (nonatomic, copy) NSDate *timestamp;
@property (nonatomic, copy) NSString *hostname;
@property (nonatomic, copy) NSString *osName;
@property (nonatomic, copy) NSString *osVersion;
@property (nonatomic, copy) NSString *architecture;
@property (nonatomic, copy) NSString *gnustepBaseVersion;
@property (nonatomic, copy) NSString *gnustepGuiVersion;
@property (nonatomic, copy) NSString *buildID;

/* Crash (SPEC section 6, required + strongly recommended) */
@property (nonatomic, copy) NSString *signal;          /* e.g. "SIGSEGV" */
@property (nonatomic, copy) NSString *exceptionName;   /* e.g. "NSInvalidArgumentException" */
@property (nonatomic, copy) NSString *exceptionReason;
@property (nonatomic, copy) NSString *faultAddress;    /* e.g. "0x18" */
@property (nonatomic, assign) NSInteger crashingThread;
@property (nonatomic, copy) NSString *instructionPointer;
@property (nonatomic, copy) NSString *stackPointer;
@property (nonatomic, copy) NSString *signalInfo;      /* raw siginfo summary */

/* Artifacts (SPEC section 5/6) */
@property (nonatomic, copy) NSString *crashDirectory;  /* absolute path */
@property (nonatomic, copy) NSString *coreDumpPath;    /* relative name within dir, or absolute */
@property (nonatomic, assign) long long coreDumpSize;
@property (nonatomic, assign) BOOL coreAvailable;
@property (nonatomic, assign) BOOL symbolsAvailable;
@property (nonatomic, copy) NSString *coreUnavailableReason;

/* Threads / backtrace (SPEC section 6, 15, 16) */
@property (nonatomic, strong) NSArray<NSDictionary *> *threads;      /* each: {id, name, crashed, frames[]} */
@property (nonatomic, strong) NSArray<NSString *> *backtrace;        /* human strings for crashing thread */
@property (nonatomic, strong) NSArray<NSString *> *loadedLibraries;  /* "name (buildID)" */
@property (nonatomic, strong) NSArray<NSString *> *registers;        /* "rip=0x..." strings */

/* Analysis (SPEC section 17) */
@property (nonatomic, copy) NSString *classification;   /* observed category */
@property (nonatomic, copy) NSString *diagnosis;        /* heuristic, may be nil */
@property (nonatomic, copy) NSString *diagnosisConfidence; /* "Certain"|"Probable"|"Possible"|"Unknown" */

/* Provenance of the crash event (SPEC section 13) */
@property (nonatomic, copy) NSString *detectionMethod;  /* "directory"|"marker"|"os" */
@property (nonatomic, copy) NSString *collector;        /* "GNUstep"|"systemd-coredump"|... */

+ (instancetype)report;

/* Load/save the canonical report.json in a crash directory. */
+ (instancetype)reportFromDirectory:(NSString *)directory;
- (BOOL)writeToDirectory:(NSString *)directory;

- (NSDictionary *)dictionaryRepresentation;
- (void)populateFromDictionary:(NSDictionary *)dict;

/* SPEC section 18: human-readable report.txt */
- (NSString *)textReport;

/* Convenience: full absolute path to a sidecar artifact by relative name. */
- (NSString *)pathForArtifact:(NSString *)name;

@end

#endif /* GSCrashReport_h */
