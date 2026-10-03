/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface GSCrashAnalyzer : NSObject

/*
 * Enrich the crash report in `dir` using an external debugger (gdb, or lldb
 * when gdb is unavailable). Returns YES on success; the resulting report.json
 * and sidecar files are written into `dir`. On fatal error returns NO and sets
 * `error`.
 */
- (BOOL)analyzeCrashDirectory:(NSString *)dir error:(NSError **)error;

/*
 * Override points used by the CLI. They are queried only when the report /
 * metadata cannot supply the value.
 */
- (void)setExecutableHint:(NSString *)path;
- (void)setCoreHint:(NSString *)path;
- (void)setTimeoutSeconds:(NSTimeInterval)seconds;

@end
