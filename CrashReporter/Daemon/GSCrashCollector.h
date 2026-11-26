/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSCrashDetector.h"
#import "GSCrashConstants.h"
#import "GSCrashReport.h"
#import "GSCrashPlatform.h"

/*
 * Given a detected crash event, GSCrashCollector builds the unique crash
 * directory, preserves the raw artifacts, merges any matching marker, runs the
 * external analyzer, and notifies the GUI (SPEC 8, 9, 13, 14, 27, 29).
 */
@interface GSCrashCollector : NSObject

- (instancetype)initWithPlatform:(id<GSCrashPlatform>)platform
                       inboxDir:(NSString *)inboxDir
                     markersDir:(NSString *)markersDir;

- (void)processEvent:(GSCrashEvent *)event;

@end
