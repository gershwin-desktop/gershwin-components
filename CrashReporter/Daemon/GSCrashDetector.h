/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSCrashPlatform.h"

/*
 * A single crash detection event handed from GSCrashDetector to the collector.
 * kind is either @"core" (Method A: a core file appeared in the inbox) or
 * @"marker" (Method C: an application marker appeared in the markers dir).
 */
@interface GSCrashEvent : NSObject

@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *executable;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy) NSString *signalName;
@property (nonatomic, copy) NSString *application;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *exception;
@property (nonatomic, copy) NSString *reason;
@property (nonatomic, copy) NSString *buildID;
@property (nonatomic, assign) uid_t uid;

- (BOOL)isValid;

@end

/*
 * Cross-platform polling detector. It watches two directories (the core inbox
 * and the markers directory) and emits stable, de-duplicated events. A file is
 * only reported once its size has been observed unchanged across two scans, so
 * a partially-written core/marker is never collected half-way (SPEC 13).
 */
@interface GSCrashDetector : NSObject

- (instancetype)initWithInbox:(NSString *)inboxDir
                      markers:(NSString *)markersDir
                     platform:(id<GSCrashPlatform>)platform;

/* Returns the events detected since the previous call. */
- (NSArray<GSCrashEvent *> *)scan;

@end
