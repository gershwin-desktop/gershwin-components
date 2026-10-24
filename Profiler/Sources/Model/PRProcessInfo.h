/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

/* One running process, as offered for profiling. */
@interface PRProcessInfo : NSObject

@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *command;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, assign) uid_t user;
@property (nonatomic, assign) unsigned long long rssBytes;
@property (nonatomic, assign) unsigned long long virtualBytes;
@property (nonatomic, assign) double cpuPercent;
/* YES when the process belongs to the user running the profiler. */
@property (nonatomic, readonly) BOOL isOwnProcess;

@end
