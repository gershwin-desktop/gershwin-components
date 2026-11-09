/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "GSCrashReport.h"
#import "GSCrashConstants.h"
#import "GSCrashPlatform.h"

@interface CrashReporterController : NSObject <NSApplicationDelegate,
                                                NSTableViewDataSource,
                                                NSTableViewDelegate>

- (void)crashDetected:(NSNotification *)note;

@end
