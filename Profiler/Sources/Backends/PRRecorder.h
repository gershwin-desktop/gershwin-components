/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "PRTypes.h"

@class PRProfile;
@class PRRecorder;

extern NSString * const PRErrorDomain;

/* What the user wants to measure. */
typedef enum {
    PRProfileModeCPU = 0,    /* where the time goes */
    PRProfileModeMemory      /* where the heap goes */
} PRProfileMode;

/* Which heap cost a memory profile shows. */
typedef enum {
    PRMemoryCostPeak = 0,    /* bytes held at the moment of peak usage */
    PRMemoryCostLeaked,      /* bytes never freed */
    PRMemoryCostAllocations, /* number of allocation calls */
    PRMemoryCostTemporary    /* allocations freed again immediately */
} PRMemoryCost;

/* How call stacks are unwound. Frame pointers are cheap but need the code
   to keep them; DWARF works everywhere but records stack snapshots. */
typedef enum {
    PRCallGraphDwarf = 0,
    PRCallGraphFramePointer,
    PRCallGraphLastBranch
} PRCallGraphMethod;

@interface PRRecordRequest : NSObject

/* Either attach to a running process ... */
@property (nonatomic, assign) pid_t pid;
/* ... or start one. */
@property (nonatomic, copy) NSString *launchPath;
@property (nonatomic, copy) NSArray *arguments;

@property (nonatomic, copy) NSString *targetName;
@property (nonatomic, assign) PRProfileMode mode;
@property (nonatomic, assign) PRMemoryCost memoryCost;
@property (nonatomic, assign) PRCallGraphMethod callGraph;
@property (nonatomic, assign) NSUInteger frequency;    /* samples per second */
@property (nonatomic, assign) NSTimeInterval duration; /* 0: until stopped */

- (BOOL)isAttach;

@end

@protocol PRRecorderDelegate <NSObject>
- (void)recorder:(PRRecorder *)recorder didReportStatus:(NSString *)status;
- (void)recorder:(PRRecorder *)recorder
    didFinishWithProfile:(PRProfile *)profile
                   error:(NSError *)error;
@end

/* Drives one external profiling tool: starts it, stops it on request and
   turns its output into a PRProfile. Subclasses implement the tool
   specifics; everything asynchronous is funneled back to the main thread. */
@interface PRRecorder : NSObject
{
    PRRecordRequest *_request;
    NSTask *_recordTask;
    NSString *_workDirectory;
    NSString *_dataPath;
    NSString *_logPath;
    NSTimer *_durationTimer;
    BOOL _recording;
    BOOL _analyzing;
    BOOL _cancelled;
}

/* Name of the tool, e.g. "perf". */
+ (NSString *)toolName;
/* Path of the tool, or nil when it is not installed. */
+ (NSString *)toolPath;
+ (BOOL)supportsMode:(PRProfileMode)mode;
/* Package to suggest when the tool is missing. */
+ (NSString *)packageName;
/* Warning to show before recording, or nil. */
+ (NSString *)warningForRequest:(PRRecordRequest *)request;

@property (nonatomic, weak) id<PRRecorderDelegate> delegate;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly, strong) PRRecordRequest *request;

- (BOOL)startWithRequest:(PRRecordRequest *)request error:(NSError **)error;
/* Ends the recording and starts turning the data into a profile. */
- (void)stopRecording;
/* Drops everything, including a running analysis. */
- (void)cancel;

/* Re-reads data already recorded under a different cost type, without
   recording again. Returns NO when the tool cannot do that. */
- (BOOL)reanalyzeWithMemoryCost:(PRMemoryCost)cost;

@end
